# Target: ba máy RHEL 9 (web / ứng dụng / CSDL)

Thứ tự: **CSDL → ứng dụng → web**. Mọi script có thể chạy lại an toàn. Các lệnh ở bước 2-4 chạy trên từng máy, trong thư mục gói phát hành đã giải nén (`/root/shop-<version>`).

Đang vận hành gì, bật/tắt thế nào: [operations.md](operations.md). Lệnh tự thực hành sự cố (tắt DB, chặn mạng, đầy đĩa...): [fault-drills.md](fault-drills.md). Kịch bản tải và sự cố: [../../scenarios/README.md](../../scenarios/README.md).

Ví dụ địa chỉ trong tài liệu: web `10.0.0.11`, ứng dụng `10.0.0.12`, CSDL `10.0.0.13`.

## 1. Đóng gói

Trên máy build có JDK 21 và Node 22, với repo `webshop` (mã nguồn ứng dụng) clone cạnh repo này hoặc chỉ định bằng tham số thứ hai / `WEBSHOP_DIR`:

```bash
cd targets/rhel-3vm
./build-release.sh 1.0.0 ../../../webshop     # -> targets/rhel-3vm/release/shop-1.0.0.tar.gz
for h in 10.0.0.11 10.0.0.12 10.0.0.13; do scp release/shop-1.0.0.tar.gz root@$h:/root/; done
# trên từng máy
cd /root && tar xzf shop-1.0.0.tar.gz && cd shop-1.0.0
```

## 2. Máy CSDL

```bash
mkdir -p /etc/shop && cp deploy/vm-db/db.env.example /etc/shop/db.env && chmod 600 /etc/shop/db.env
vi /etc/shop/db.env            # BACKEND_HOST, hai mật khẩu database, KAFKA_ADVERTISED_HOST (IP máy này)
./deploy/vm-db/install.sh
```

Script cài PostgreSQL 16, tạo database `shop` và `payments` cùng user riêng, bật `pg_stat_statements`, ghi log câu lệnh chậm hơn 1 giây, chỉ cho máy ứng dụng kết nối (pg_hba + firewalld), đặt lịch backup 02:30 hằng ngày (`/var/lib/pgsql/backups/shop`, giữ 7 bản).

Với `KAFKA_ENABLED=true`, `install.sh` gọi tiếp `deploy/vm-db/kafka.sh`: cài Java 21, tải Apache Kafka 4.3.1 từ `downloads.apache.org` (kiểm tra SHA-512; máy không ra Internet được thì đặt `KAFKA_TGZ=/đường/dẫn/kafka_2.13-4.3.1.tgz`), chạy một node KRaft (không ZooKeeper) bằng service `kafka`, heap 512 MB, chỉ mở cổng 9092 cho máy ứng dụng. Chỉ cài/sửa Kafka mà không đụng PostgreSQL: `./deploy/vm-db/kafka.sh`.

## 3. Máy ứng dụng

```bash
mkdir -p /etc/shop && cp deploy/vm-app/app.env.example /etc/shop/app.env && chmod 600 /etc/shop/app.env
vi /etc/shop/app.env
./deploy/vm-app/install.sh
./deploy/vm-app/deploy.sh payment payment/payment-gateway.jar
./deploy/vm-app/deploy.sh backend backend/shop-backend.jar
```

| Biến | Ý nghĩa |
|---|---|
| `DB_HOST`, `DB_PASSWORD`, `PAYMENT_DB_PASSWORD` | Trùng với máy CSDL |
| `PAYMENT_API_KEY` | Khóa dùng chung giữa backend và cổng thanh toán: `openssl rand -hex 24` |
| `JWT_SECRET` | `openssl rand -base64 48` |
| `APP_ADMIN_EMAIL`, `APP_ADMIN_PASSWORD` | Tài khoản quản trị, tạo ở lần khởi động đầu |
| `FRONTEND_HOST`, `APP_TRUSTED_PROXY` | IP máy web (trong regex phải escape dấu chấm, để trong nháy đơn) |
| `ADMIN_SUBNET` | Mạng được gọi cổng 8081 (health, metrics) |
| `APP_SEED_ENABLED` | `true`: nạp dữ liệu mẫu (96 sản phẩm, ~250 khách, 90 ngày đơn hàng) khi database trống |
| `APP_SIMULATION_ENABLED` | `true`: bật trang mô phỏng sự cố |
| `APP_RELEASE_VERSION`, `APP_RELEASE_STAGE` | Phiên bản và môi trường, hiện ở `/actuator/info` |

`deploy.sh` thay jar, khởi động lại và chờ `/actuator/health/readiness` báo `UP`; nếu không lên thì tự quay về bản trước.

Hai kiểu chạy trên cùng máy:

| Dịch vụ | Kiểu | Chi tiết |
|---|---|---|
| `shop-backend` | Tiến trình Java, systemd | Cổng 8080, health 8081. Jar ở `/opt/shop/backend`, log JSON `/var/log/shop/backend.log` |
| `shop-payment` | Container Docker, systemd chạy `docker run` | `deploy.sh payment` build image `shop-payment:<thời gian>` từ `payment/Containerfile` (nền `registry.access.redhat.com/ubi9/openjdk-21-runtime`), gắn tag `:current`, giữ bản trước ở `:prev` để quay lại. Chỉ publish `127.0.0.1:8090`. Log JSON `/var/log/shop-payment/payment.log` |

`install.sh` cài Docker CE từ repo chính thức `download.docker.com` (gói `containerd.io` thay gói `runc` của RHEL), tải image nền, sinh `/etc/shop/payment.env` từ `app.env` (lệnh `shop-payment-env`) và cài unit `shop-payment.service`. Nếu máy đang chạy cách cũ (service Java hoặc unit Podman/Quadlet), script tự gỡ. Máy ứng dụng cần ra được Internet tới `download.docker.com` và `registry.access.redhat.com`.

Hàng đợi đơn hàng: đặt `APP_KAFKA_BOOTSTRAP=10.0.0.13:9092` trong `app.env` (để trống thì không dùng hàng đợi). Backend tự tạo topic `orders` khi khởi động.

### Hàng đợi Kafka và công cụ giám sát

Trace bất đồng bộ (đặt hàng → bản ghi Kafka → consumer kho) do agent Java gắn sẵn vào header bản ghi, không cần sửa code. Kiểm tra header trên máy CSDL:

```bash
runuser -u kafka -- /opt/kafka/current/bin/kafka-console-consumer.sh --bootstrap-server 127.0.0.1:9092 --topic orders \
  --from-beginning --max-messages 3 --formatter-property print.headers=true --formatter-property print.value=false --timeout-ms 10000 \
  | grep -a -o 'traceparent:[^,]*'
```

Ra được dòng `traceparent:00-...` là trace sẽ nối được (một số agent gắn thêm header riêng dạng nhị phân).

| Công cụ | Cần làm |
|---|---|
| Dynatrace | Trace producer/consumer: tự có (đã thấy `traceparent`, `X-dynaTrace` trên bản ghi). Metric broker, topic, consumer group: kích hoạt extension **Apache Kafka** từ Hub cho host CSDL |
| Instana | Agent trên host CSDL tự nhận broker Kafka (sensor Kafka); trace producer/consumer tự có từ agent Java trên máy ứng dụng |
| Công cụ khác / chung | Lag và số consumer có sẵn ở `/actuator/prometheus` cổng 8081: `shop_events_lag`, `shop_events_consumers` (đo từ broker, vẫn đúng khi consumer chết), `shop_events_unsent` (số đơn chưa gửi được) |

#### Để dừng Kafka thành cảnh báo

Kafka là phần phụ trợ: dừng nó thì cửa hàng vẫn bán, mọi request vẫn trả 200. Không cấu hình gì thì công cụ giám sát thường **im lặng**. Ứng dụng để lại các dấu hiệu sau (chi tiết: [fault-drills.md mục 2.8](fault-drills.md#28-dừng-kafka)); chọn một vài cách bắt dưới đây, cách 1 cho cảnh báo nhanh nhất.

| # | Dấu hiệu | Dynatrace | Công cụ khác |
|---|---|---|---|
| 1 | Tiến trình Kafka biến mất trên svdb | **Settings → Processes and containers → Process availability**: thêm rule (ví dụ tên "Kafka", điều kiện command line chứa `kafka.Kafka`, phạm vi host svdb). Dừng Kafka → problem "Process unavailable" trong khoảng 1 phút. Làm tương tự cho `postgres`, `nginx`, `shop-backend.jar` | Cảnh báo tiến trình/dịch vụ systemd dừng |
| 2 | Request đặt hàng có header `X-Order-Queue: FAILED` | Tạo **request attribute** từ response header `X-Order-Queue` (service `shop-backend`), rồi **Failure detection → custom error rule**: request attribute = `FAILED` thì tính là lỗi. `/api/orders` khi đó có tỷ lệ lỗi tăng vọt → problem theo tỷ lệ lỗi | Lọc/cảnh báo theo header hoặc span attribute |
| 3 | `/api/orders` chậm thêm ~3 giây | Tự thấy trên service `shop-backend`; problem response time cần baseline đã học (xem [scenarios/README.md mục 4](../../scenarios/README.md#4-điều-kiện-để-công-cụ-giám-sát-mở-cảnh-báo)) hoặc ngưỡng cố định cho request `/api/orders` | Cảnh báo độ trễ theo endpoint |
| 4 | Log ERROR `could not be sent to the queue`, WARN `Order queue still unavailable` | Thu log `/var/log/shop/backend.log` (Log ingest rule), rồi **Log events**: nội dung chứa `could not be sent to the queue` → sự kiện loại Error, mở problem | Cảnh báo theo log |
| 5 | `/actuator/health` cổng 8081 trả 503 (`orderQueue` DOWN) | **HTTP monitor** (synthetic) tới `http://192.168.50.65:8081/actuator/health` từ một ActiveGate trong mạng 192.168.50.0/24 | Bất kỳ HTTP check nào |
| 6 | Metric broker biến mất, `shop_events_unsent` tăng | Extension **Apache Kafka** cho host svdb (broker offline); `shop_events_unsent` cần đưa metric Prometheus vào công cụ | Scrape `/actuator/prometheus`, cảnh báo `shop_events_unsent > 0` |

### Dịch vụ chấm điểm rủi ro (Python)

```bash
./deploy/vm-app/deploy.sh risk risk        # build image từ thư mục risk/ (chạy unit test khi build), chạy container shop-risk
```

Python **không tự được gắn agent như Java**. Tuỳ công cụ giám sát:

| Công cụ | Cần làm |
|---|---|
| Instana | Trong `app.env`: `RISK_EXTRA_PIP_PACKAGES=instana` và `RISK_AUTOWRAPT_BOOTSTRAP=instana`, rồi `deploy.sh risk risk` (build lại image có gói `instana`) |
| Dynatrace | OneAgent trên host; bật **Settings → Preferences → OneAgent features → Python** và **Python FastAPI [Opt-In]**, rồi `systemctl restart shop-risk`. Không cần đổi image |
| Công cụ khác | Gói Python của công cụ qua `RISK_EXTRA_PIP_PACKAGES`, biến khởi động qua `RISK_AUTOWRAPT_BOOTSTRAP` (nếu công cụ dùng autowrapt) |

Kiểm tra: một trace đặt hàng phải đi từ nginx → backend (Java) → **risk (Python)** → quay về; bật kịch bản `RISK_SLOW` thì thời gian chờ nằm ở dịch vụ Python.

## 4. Máy web

```bash
mkdir -p /etc/shop && cp deploy/vm-web/web.env.example /etc/shop/web.env
vi /etc/shop/web.env           # APP_DOMAIN (tên miền hoặc IP), BACKEND_UPSTREAM=10.0.0.12:8080
./deploy/vm-web/install.sh
./deploy/vm-web/deploy.sh frontend/dist
```

nginx phục vụ giao diện, ảnh `/images/`, chuyển `/api/` sang backend và chặn `/actuator`. SELinux được cấu hình sẵn (`httpd_can_network_connect`, context cho `/var/www/shop`). Nếu đặt chứng chỉ vào `/etc/nginx/certs/fullchain.pem` và `privkey.pem` rồi chạy `shop-render-nginx`, site tự chuyển sang HTTPS.

## 5. Kiểm tra

```bash
../../smoke/smoke-test.sh http://10.0.0.11 '<APP_ADMIN_PASSWORD>'
```

Khoảng 60 bước: xem hàng, giỏ hàng, mã giảm giá, đặt hàng COD và thẻ (thành công, bị từ chối, hoàn kho), tài khoản, phân quyền, quy trình đơn trong trang quản trị, hoàn tiền, và kiểm tra các cổng nội bộ không lộ ra ngoài.

## 6. Cập nhật

```bash
./build-release.sh 1.0.1 ../../../webshop     # rồi chép gói lên máy như bước 1
./deploy/vm-app/deploy.sh backend backend/shop-backend.jar
./deploy/vm-web/deploy.sh frontend/dist
```

Quay lại bản trước: `deploy.sh backend /opt/shop/backend/shop-backend.jar.prev`; cổng thanh toán: `docker tag shop-payment:prev shop-payment:current && systemctl restart shop-payment`; giao diện: trỏ lại symlink `/var/www/shop/current` sang thư mục cũ trong `releases/` rồi `systemctl reload nginx`.

## 7. Xử lý sự cố

| Hiện tượng | Kiểm tra |
|---|---|
| 502 trên web | Từ máy web: `curl http://10.0.0.12:8080/api/site-config` phải trả 200; `getsebool httpd_can_network_connect` phải là `on` |
| Backend không lên | `journalctl -u shop-backend -n 200`; kết nối DB, `firewall-cmd --list-rich-rules` trên máy CSDL |
| Thanh toán thẻ luôn lỗi | `systemctl status shop-payment`; `PAYMENT_API_KEY` giống nhau; trang **Cổng thanh toán** có đang bật lỗi/ngừng hoạt động |
| Đơn kẹt "Chờ kho nhận" | Kịch bản `KAFKA_*` còn bật? `systemctl status kafka` trên máy CSDL; `kafka-consumer-groups.sh --describe --group shop-warehouse` (xem [operations.md](operations.md#kafka-svdb)) |
| Truy vấn chậm | Máy CSDL: `/var/lib/pgsql/data/log/`; `SELECT * FROM pg_stat_statements ORDER BY total_exec_time DESC LIMIT 10` |
