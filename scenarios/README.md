# Kịch bản: tải giả lập và sự cố

Hai công cụ cho môi trường thử nghiệm: tạo lưu lượng như người dùng thật và bật sự cố có kiểm soát. Không phụ thuộc hệ thống giám sát nào. Không dùng trên hệ thống có dữ liệu thật.

Cần ứng dụng chạy với `APP_SEED_ENABLED=true` (tài khoản mẫu, sản phẩm) và `APP_SIMULATION_ENABLED=true` (API sự cố).

## 1. Tải giả lập (k6)

Chạy từ một máy riêng, không đặt trên ba máy của cửa hàng.

```bash
cd load
ADMIN_PASSWORD='<APP_ADMIN_PASSWORD>' ./run.sh http://shop.example.com smoke          # 1 người dùng, 1 phút
ADMIN_PASSWORD='<APP_ADMIN_PASSWORD>' ./run.sh http://shop.example.com steady 10 2h    # 10 người dùng, 2 giờ
ADMIN_PASSWORD='<APP_ADMIN_PASSWORD>' ./run.sh http://shop.example.com spike 10        # tăng đột biến lên 30
```

| Nhóm | Tỷ lệ | Hành vi |
|---|---|---|
| Xem hàng | 55% | Trang chủ → danh mục / tìm kiếm / lọc size → 1-3 trang sản phẩm |
| Mua hàng | 25% | Xem hàng → báo giá giỏ (đôi khi có mã giảm giá) → 70% đặt hàng: COD hoặc thẻ (một số thẻ bị từ chối) |
| Khách quen | 10% | Đăng nhập `loadNN@saibuoc.vn` → lịch sử đơn → chi tiết đơn |
| Tra cứu | 5% | Tra cứu đơn bằng mã và số điện thoại |
| Quản trị | 5% | Tổng quan → xác nhận / giao / hoàn tất đơn → nhập thêm hàng cho size đã hết |

Chỉ số riêng: `orders_placed`, `orders_payment_failed`, `checkout_duration`. Tải nền liên tục: `load/shop-load.service` (systemd hệ thống) hoặc `load/shop-load.user.service` (systemd của một user, không cần root); hướng dẫn trong từng file.

## 2. Mô phỏng sự cố

Bật `APP_SIMULATION_ENABLED=true`. Vào **Quản trị → Mô phỏng sự cố**. Mỗi kịch bản có thời lượng (1-240 phút) và tự tắt; mọi lần bật/tắt được ghi log.

| Kịch bản | Tác động | Nơi thấy rõ |
|---|---|---|
| `LATENCY` | Độ trễ ngẫu nhiên cho một nhóm API | Thời gian phản hồi nhóm API đó, trải nghiệm trang |
| `HTTP_ERROR` | Một tỷ lệ request ném exception thật (HTTP 500) | Tỷ lệ lỗi, stack trace trong log |
| `SLOW_SQL` | Danh sách/tìm kiếm sản phẩm chạy thêm câu SQL `pg_sleep` | Thời gian truy vấn database, log câu lệnh chậm |
| `N_PLUS_ONE` | Danh sách sản phẩm truy vấn size từng sản phẩm một | Số câu SQL mỗi request tăng vọt |
| `POOL_EXHAUSTION` | Request giữ kết nối DB lâu, cạn connection pool | Mọi API chậm dần, readiness có thể DOWN |
| `HIGH_CPU` | Trang sản phẩm tính gợi ý tốn CPU | CPU tiến trình backend, hotspot ở `CatalogService.related` |
| `MEMORY_LEAK` | Mỗi request giữ lại bộ nhớ (có giới hạn) | Heap tăng, GC tăng; nút "Giải phóng bộ nhớ" |
| `FRONTEND_ERROR` | Nút "Thêm vào giỏ" ném `TypeError` | Lỗi JavaScript phía trình duyệt; khách không thêm được hàng |

Nhóm API: `ALL`, `CATALOG`, `CART`, `CHECKOUT`, `ACCOUNT`, `ADMIN`.

API tương ứng (cần token quản trị):

```
GET  /api/admin/simulation
PUT  /api/admin/simulation/{SCENARIO}   {"active": true, "params": {...}, "durationMinutes": 15}
POST /api/admin/simulation/release-memory
```

## 3. Sự cố ở dịch vụ thanh toán

**Quản trị → Cổng thanh toán** điều khiển một tiến trình riêng (`shop-payment`):

| Cấu hình | Kết quả cho khách | Kết quả trong hệ thống |
|---|---|---|
| Độ trễ thêm 4 giây | Thanh toán thẻ chậm | Thời gian gọi dịch vụ ngoài tăng, `checkout_duration` tăng |
| Độ trễ thêm 10 giây | "Cổng thanh toán đang gặp sự cố" sau 8 giây | Backend timeout, HTTP 502, đơn "Thanh toán thất bại", tồn kho được hoàn |
| Tỷ lệ lỗi 30% | Một phần đơn thẻ thất bại | Dịch vụ thanh toán trả 502, lỗi lan sang backend |
| Ngừng hoạt động | Mọi đơn thẻ thất bại, COD vẫn chạy | 503 từ dịch vụ thanh toán; tỷ lệ thất bại trên trang Tổng quan tăng |

Sự cố hạ tầng làm thủ công:

```bash
systemctl stop shop-payment        # máy ứng dụng: thanh toán thẻ lỗi kết nối, COD vẫn chạy
systemctl stop postgresql          # máy CSDL: toàn bộ API lỗi, readiness DOWN
systemctl stop shop-backend        # máy ứng dụng: nginx trả 502
```

## 4. Điều kiện để công cụ giám sát mở cảnh báo

Một kịch bản chỉ gây hậu quả khi **có request đi qua**. Bật sự cố lúc không có tải (hoặc tải chỉ bắt đầu sau khi kịch bản đã hết hạn) thì không có gì để phát hiện.

- **Luôn chạy tải nền trước**, rồi mới bật kịch bản. Kiểm tra: `systemctl --user is-active shop-load` trên máy chạy tải.
- **Đặt thời lượng kịch bản đủ dài**, 20-30 phút. Các cơ chế phát hiện bất thường cần sự cố kéo dài nhiều phút liên tục, không tính đột biến ngắn.
- **Dịch vụ mới cần thời gian học mức bình thường.** Cảnh báo dựa trên baseline tự học (tỷ lệ lỗi, tải tăng/giảm) cần dữ liệu từ khoảng hơn một ngày đến một tuần. Mỗi lần đổi cách chạy một dịch vụ (ví dụ chuyển sang container), hệ thống giám sát có thể coi đó là dịch vụ mới và học lại từ đầu, nên hạn chế thay đổi hạ tầng sát ngày demo.
- **Cảnh báo theo ngưỡng cố định hoạt động ngay**, không cần học: CPU host bão hòa, hết bộ nhớ, tiến trình hoặc dịch vụ ngừng hoạt động. Để có cảnh báo ngay trong ngày đầu, ưu tiên các kịch bản: `HIGH_CPU` với `cpuMs` 4000-5000 (đẩy CPU máy ứng dụng lên gần 100%), dừng hẳn `shop-payment` hoặc `shop-backend`, hoặc đặt ngưỡng thời gian phản hồi / tỷ lệ lỗi cố định cho dịch vụ trong cấu hình phát hiện bất thường.
- Dịch vụ có ít request (dưới khoảng 10 request/phút) có thể bị bỏ qua để tránh báo nhiễu. Với 10 người dùng ảo, backend nhận khoảng 300 request/phút; cổng thanh toán chỉ khoảng 3-4 request/phút, nên muốn cảnh báo trên cổng thanh toán thì tăng `VUS` trong `~/.config/shop-load/env` lên 30-40.

## 5. Gợi ý một buổi demo

1. Chạy tải nền liên tục từ ít nhất 1-2 ngày trước (để có baseline), tối thiểu vài giờ.
2. Mở trang khách hàng, đặt một đơn bằng thẻ, theo dõi request đi qua nginx → backend → dịch vụ thanh toán → hai database.
3. Bật `SLOW_SQL` 3000 ms trong 30 phút → chỉ ra câu SQL nguyên nhân.
4. Đặt cổng thanh toán "Quá thời gian chờ" → đơn thẻ thất bại, tỷ lệ thất bại trên trang Tổng quan tăng → chỉ ra dịch vụ ngoài là gốc.
5. Bật `FRONTEND_ERROR` → khách không thêm được hàng vào giỏ, số đơn giảm dù server không có lỗi nào.
6. Tắt các kịch bản, đưa cổng thanh toán về "Bình thường".
