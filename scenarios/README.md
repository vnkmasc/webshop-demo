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

Tỷ lệ mỗi nhóm đổi được bằng biến môi trường: `BUY_PERCENT` (mặc định 25), `CUSTOMER_PERCENT` (10), `TRACK_PERCENT` (5), `ADMIN_PERCENT` (5); phần còn lại là xem hàng.

Các nhóm trên chủ yếu xem và tìm sản phẩm: đặt hàng chỉ chiếm vài phần trăm số request. Vì vậy có thêm luồng **đặt hàng đều đặn** chạy song song: `ORDERS_PER_MIN` lượt mỗi phút (mặc định 6, 0 = tắt), mỗi lượt: xem sản phẩm → báo giá giỏ → đặt hàng (`CARD_PERCENT`, mặc định 50% trả bằng thẻ; 30% đặt khi đã đăng nhập `loadNN`) → tra cứu lại đơn vừa đặt. Đây là luồng giữ cho thanh toán, chấm điểm rủi ro và hàng đợi Kafka luôn có việc.

Tải nền chạy liên tục nên để nhẹ (`VUS=2 BUY_PERCENT=2 ORDERS_PER_MIN=1`, ~60 request/phút, ~70 đơn/giờ); khi demo tăng lên `VUS=10 BUY_PERCENT=25 ORDERS_PER_MIN=10`.

Mọi đơn do kịch bản tạo có ghi chú `k6` để phân biệt và dọn (target `rhel-3vm`: lịch `shop-load-cleanup` trên máy CSDL).

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
| `PAYMENT_BUSINESS_ERROR` | Cổng thanh toán trả **HTTP 200** nhưng body có `responseCode` 99/68/12 (kiểu core banking), kèm header `X-Response-Code`; backend coi là thất bại: đơn "Thanh toán thất bại", hoàn kho | Call sang cổng thanh toán vẫn **hiện thành công** cho tới khi cấu hình bắt header `X-Response-Code` / đánh dấu lỗi theo log (`Core banking responded code ...` mức WARN); tỷ lệ thanh toán thẻ thất bại trên trang Tổng quan tăng |
| `ODD_STATUS` | Một tỷ lệ request của một nhóm API trả 423/402/451/429 với body `error`, `message` (423, 429 có `Retry-After: 30`) | Lọc request theo mã trạng thái HTTP; các mã này không lẫn với lỗi thật |
| `READINESS_FAIL` | `/actuator/health/readiness` báo DOWN, liveness vẫn UP (tiến trình không bị khởi động lại) | `/actuator/health/readiness` (cổng 8081) trả 503/DOWN trong khi liveness UP; công cụ hoặc bộ cân bằng tải nào theo dõi readiness sẽ thấy backend không sẵn sàng. Target `rhel-3vm` không có kiểm tra readiness định kỳ, nên shop vẫn phục vụ bình thường |
| `EMIT_PII` | Thanh toán thẻ đính dữ liệu **giả** cố định vào URL (`customer.email`, `payment.card_number`, `payment.card_cvv`), header (`X-Customer-Email`, `X-Card-Number`, `X-Card-Cvv`) của lệnh gọi sang cổng thanh toán và vào log | Trace (URL, header của call sang cổng thanh toán) và log hiện số thẻ khi chưa cấu hình che; cấu hình che xong thì biến mất |
| `RISK_SLOW` | Dịch vụ chấm điểm rủi ro (Python) trả lời chậm thêm `delayMs` (2000) | Thời gian đặt hàng tăng; trên trace, thời gian chờ nằm ở **dịch vụ Python**, không phải backend Java |
| `RISK_ERROR` | `percent` (30) lời gọi chấm điểm trả 500 | Lỗi ở dịch vụ Python; backend ghi WARN "Risk service failed", **đơn vẫn đặt được** (không có điểm) |
| `RISK_TIMEOUT` | Dịch vụ chấm điểm trả lời sau `delayMs` (5000), quá timeout 3 giây của backend | Đặt hàng chậm thêm ~3 giây, call sang dịch vụ Python bị cắt; đơn vẫn đặt được |
| `KAFKA_SLOW_CONSUMER` | Kho (consumer group `shop-warehouse`) xử lý mỗi đơn từ topic `orders` chậm thêm `delayMs` (15000 trên giao diện, tối đa 20000) | Lag của group tăng khi đơn đến nhanh hơn tốc độ xử lý (cần tải mức demo, ~7 đơn/phút), rồi rút về 0 khi tắt; trace consumer dài ra; đơn kẹt "Chờ kho nhận" lâu hơn, lịch sử đơn ghi số giây đã chờ. Khách đặt hàng **không chậm** |
| `KAFKA_CONSUMER_DEAD` | Consumer kho ngừng hẳn (rời group) trong khi backend vẫn gửi sự kiện | Số thành viên consumer group về 0, lag tăng đều; mọi đơn mới kẹt "Chờ kho nhận". Tắt (hoặc hết giờ) thì consumer đọc lại từ chỗ dừng, lag rút về 0 |
| `METRIC_CARDINALITY` | Counter `shop.request.tagged` gắn tag `request_ref` khác nhau mỗi request; dừng ở ngưỡng (tối đa 5.000 series), tắt thì xoá hết | Số series của metric tăng vọt rồi dừng (`/actuator/prometheus` cổng 8081 phình từ ~30 KB lên ~450 KB); trang Mô phỏng sự cố hiện số series |

Nhóm API: `ALL`, `CATALOG`, `CART`, `CHECKOUT`, `ACCOUNT`, `ADMIN`.

Tham số các kịch bản mới:

| Kịch bản | Tham số (mặc định) |
|---|---|
| `PAYMENT_BUSINESS_ERROR` | `code`: `99` core bận / `68` tài khoản không đủ điều kiện / `12` sai định dạng (`99`); `percent` (40). Cổng thanh toán giữ cùng hạn tự tắt, và được tắt khi backend khởi động lại |
| `ODD_STATUS` | `code`: 423 / 402 / 451 / 429 (423); `percent` (40); `target` (`ALL`) |
| `KAFKA_SLOW_CONSUMER` | `delayMs`: thời gian thêm cho mỗi đơn, tối đa 20000 (5000 nếu gọi API không truyền; giao diện điền sẵn 15000) |
| `METRIC_CARDINALITY` | `perRequest`: series mới mỗi request, 1-50 (10); `maxSeries`: ngưỡng, tối đa 5000 (5000) |

Dữ liệu của `EMIT_PII` **luôn là dữ liệu giả cố định**: số thẻ test công khai `4111111111111111`, email `demo@example.com`, CVV `000`; không lấy từ dữ liệu khách nhập.

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

Sự cố hạ tầng làm thủ công (danh sách đầy đủ kèm lệnh khôi phục cho target `rhel-3vm`: [../targets/rhel-3vm/fault-drills.md](../targets/rhel-3vm/fault-drills.md)):

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
- Dịch vụ có ít request (dưới khoảng 10 request/phút) có thể bị bỏ qua để tránh báo nhiễu. Ở mức tải nền, backend nhận ~55 request/phút nhưng cổng thanh toán gần như không có request; trước khi demo sự cố thanh toán, chuyển sang mức demo (`VUS=10 BUY_PERCENT=25 ORDERS_PER_MIN=10`, cổng thanh toán ~8 request/phút) hoặc tăng riêng `ORDERS_PER_MIN`.

## 5. Gợi ý một buổi demo

1. Chạy tải nền liên tục từ ít nhất 1-2 ngày trước (để có baseline), tối thiểu vài giờ.
2. Mở trang khách hàng, đặt một đơn bằng thẻ, theo dõi request đi qua nginx → backend → dịch vụ thanh toán → hai database.
3. Bật `SLOW_SQL` 3000 ms trong 30 phút → chỉ ra câu SQL nguyên nhân.
4. Đặt cổng thanh toán "Quá thời gian chờ" → đơn thẻ thất bại, tỷ lệ thất bại trên trang Tổng quan tăng → chỉ ra dịch vụ ngoài là gốc.
5. Bật `KAFKA_CONSUMER_DEAD` 20 phút ở tải mức demo → lag của consumer group tăng đều, group không còn thành viên; tắt đi, lag rút về 0; mở một đơn để thấy trace nối từ lúc đặt sang lúc kho xử lý.
6. Bật `FRONTEND_ERROR` → khách không thêm được hàng vào giỏ, số đơn giảm dù server không có lỗi nào.
7. Tắt các kịch bản, đưa cổng thanh toán về "Bình thường".
