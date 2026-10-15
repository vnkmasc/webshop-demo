# Bắt đầu từ đây

Hướng dẫn cho người mới: **xem gì, đọc gì, làm gì, test gì**, theo đúng thứ tự. Mọi lệnh dùng môi trường demo hiện tại (target [`rhel-3vm`](targets/rhel-3vm/README.md)):

| Máy | IP | Chạy gì |
|---|---|---|
| svfrt | 192.168.50.64 | nginx (trang web) |
| svbe | 192.168.50.65 | backend Java, cổng thanh toán (container), chấm điểm rủi ro Python (container) |
| svdb | 192.168.50.66 | PostgreSQL, hàng đợi Kafka (topic `orders`) |
| control-plane | 192.168.50.46 | master của cụm Kubernetes; tải giả lập k6 chạy thành 2 pod (namespace `shop-loadgen`) trên worker-1 và worker-2 |

## 1. Xem gì trước (10 phút): làm quen sản phẩm

1. **Trang bán hàng** http://192.168.50.64: xem một đôi giày, thêm vào giỏ, đặt một đơn **COD** và một đơn **thẻ** `4111 1111 1111 1111` (hạn `12/30`, CVV `123`).
2. **Trang quản trị** http://192.168.50.64/admin: `admin@saibuoc.vn`, mật khẩu là `APP_ADMIN_PASSWORD` trong `/etc/shop/app.env` trên svbe.
   - **Tổng quan**: doanh thu, tỷ lệ thanh toán thẻ thất bại.
   - **Đơn hàng**: hai đơn vừa đặt, cột **Rủi ro** (điểm do dịch vụ Python chấm) và cột **Kho** ("Kho đã nhận" sau khoảng 1 giây, qua hàng đợi Kafka).
   - **Mô phỏng sự cố**: các thẻ bật/tắt sự cố, chỗ dùng nhiều nhất khi demo.
3. **Trên công cụ giám sát**, tìm:
   - 3 host svfrt, svbe, svdb;
   - các service: nginx, `shop-backend` (Java), `payment-gateway` (Java, container), `risk` (Python, container), PostgreSQL, Kafka (tiến trình Java trên svdb);
   - **một trace của đơn thẻ vừa đặt**: nginx → backend → risk (Python) → payment → database.

   - trace đó còn có một nhánh **bất đồng bộ**: backend gửi bản ghi vào Kafka, rồi consumer `shop-warehouse` (kho) xử lý.

   Thấy được trace đó là phần nền đã ổn. Python cần cấu hình riêng tùy công cụ, xem [targets/rhel-3vm/README.md](targets/rhel-3vm/README.md#dịch-vụ-chấm-điểm-rủi-ro-python).

## 2. Đọc gì (theo thứ tự)

| # | Tài liệu | Để làm gì |
|---|---|---|
| 1 | [targets/rhel-3vm/operations.md](targets/rhel-3vm/operations.md) | Cái gì đang chạy ở đâu, bật/tắt từng phần, tắt toàn bộ. Đọc để không sợ làm hỏng |
| 2 | [scenarios/README.md](scenarios/README.md) | Danh sách kịch bản sự cố: tác động và nơi thấy rõ. **Đọc kỹ mục 4** (điều kiện để công cụ giám sát mở cảnh báo) |
| 3 | [targets/rhel-3vm/fault-drills.md](targets/rhel-3vm/fault-drills.md) | Lệnh tự gây sự cố hạ tầng (tắt DB, chặn mạng, đầy đĩa, kill tiến trình...) kèm lệnh khôi phục. Đọc khi đã quen |
| - | [README](https://github.com/vnkmasc/webshop) của repo `webshop` | Chỉ khi cần hiểu bên trong ứng dụng (cấu hình, API) |

## 3. Bài tập mẫu đầu tiên (30 phút): SQL chậm

Kịch bản dễ thấy nhất; làm được bài này là dùng được mọi kịch bản khác.

1. **Tăng tải lên mức demo** (trên control-plane, user `cp`, dùng `kubectl`):
   ```bash
   kubectl -n shop-loadgen patch cm shop-loadgen --type merge -p '{"data":{"VUS":"5","BUY_PERCENT":"25","ORDERS_PER_MIN":"5"}}' && kubectl -n shop-loadgen rollout restart deploy/shop-loadgen
   ```
2. Đợi ~10 phút, ghi lại thời gian phản hồi bình thường của `shop-backend` trên công cụ giám sát.
3. **Quản trị → Mô phỏng sự cố**, bật thẻ **SQL chậm** (3000 ms, 30 phút).
4. Trên công cụ giám sát:
   - service `shop-backend`: thời gian phản hồi tăng;
   - phần database: câu SQL có `pg_sleep` nổi lên đầu;
   - một trace chậm: thời gian nằm ở câu SQL đó;
   - danh sách cảnh báo/problem: có thể có hoặc chưa (xem mục 4 của [scenarios/README.md](scenarios/README.md)).
5. **Tắt** kịch bản, **trả tải** về mức nền:
   ```bash
   kubectl -n shop-loadgen patch cm shop-loadgen --type merge -p '{"data":{"VUS":"1","BUY_PERCENT":"2","ORDERS_PER_MIN":"1"}}' && kubectl -n shop-loadgen rollout restart deploy/shop-loadgen
   ```

## 4. Test gì tiếp: mỗi lần một kịch bản

| # | Kịch bản (thẻ trong Mô phỏng sự cố) | Điều cần chứng minh với khách |
|---|---|---|
| 1 | SQL chậm | Chỉ ra đúng câu SQL gây chậm |
| 2 | **Cổng thanh toán** → "Quá thời gian chờ" | Lỗi đến từ dịch vụ phụ thuộc, không phải code shop |
| 3 | Lỗi 500 (nhóm Đặt hàng) | Stack trace và log của đúng request lỗi; log có sẵn trace id |
| 4 | **Lỗi nghiệp vụ trong body** | Công cụ báo **thành công** dù giao dịch thất bại, cho tới khi cấu hình bắt header `X-Response-Code`. Điểm bán hàng mạnh nhất với khách ngân hàng |
| 5 | Dịch vụ rủi ro chậm / quá thời gian chờ | Trace xuyên Java → Python; thời gian chờ nằm ở dịch vụ Python; tắt dịch vụ Python khách vẫn mua được |
| 5b | **Consumer hàng đợi chết** / Hàng đợi xử lý chậm | Lag consumer group tăng rồi rút; group về 0 thành viên; trace nối từ lúc đặt hàng sang lúc kho xử lý. Cần tải mức demo |
| 6 | Lộ dữ liệu nhạy cảm (giả) | Thấy số thẻ test trong trace/log → cấu hình che → biến mất |
| 7 | Mã HTTP lạ (423/451...) | Lọc, cảnh báo theo mã trạng thái HTTP |
| 8 | Readiness hỏng | Endpoint readiness báo DOWN trong khi tiến trình vẫn sống (liveness UP); cần công cụ giám sát theo dõi endpoint này (ví dụ synthetic/HTTP monitor tới cổng 8081) |
| 9 | CPU cao, Rò bộ nhớ, Nổ cardinality metric | Profiling chỉ đúng hàm; heap; số series metric |
| 10 | Lỗi JavaScript | Phải **tự mở trình duyệt** (tải giả lập không chạy JavaScript): lỗi phía người dùng |
| 11 | Bài tập hạ tầng | Theo [fault-drills.md](targets/rhel-3vm/fault-drills.md). Bài firewall/mạng: chuẩn bị sẵn console VM trên hypervisor |

## 5. Nguyên tắc để thấy được kết quả

- **Tải trước, sự cố sau.** Không có lưu lượng thì sự cố không ảnh hưởng ai, công cụ giám sát không có gì để thấy.
- **Mỗi lần một kịch bản**, để **15-30 phút**, tắt hẳn rồi mới sang cái khác.
- **Dịch vụ mới cần thời gian học**: cảnh báo tự động theo baseline cần từ hơn một ngày tới một tuần dữ liệu. Muốn có cảnh báo ngay, dùng ngưỡng cố định (CPU, tiến trình chết, đĩa đầy) hoặc tự đặt ngưỡng cho service.
- Không thấy gì: kiểm tra `kubectl -n shop-loadgen get pods` trên control-plane (2 pod tải phải `Running`) và kịch bản đã bật đủ lâu chưa.
- Kịch bản tự tắt khi hết thời gian; khởi động lại backend cũng tắt hết. Không chắc còn gì đang bật: [fault-drills.md mục 6](targets/rhel-3vm/fault-drills.md#6-khôi-phục-tất-cả).
