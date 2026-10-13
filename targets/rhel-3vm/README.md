# Target: ba máy RHEL 9 (web / ứng dụng / CSDL)

Thứ tự: **CSDL → ứng dụng → web**. Mọi script có thể chạy lại an toàn. Các lệnh ở bước 2-4 chạy trên từng máy, trong thư mục gói phát hành đã giải nén (`/root/shop-<version>`).

Đang vận hành gì, bật/tắt thế nào: [operations.md](operations.md). Kịch bản tải và sự cố: [../../scenarios/README.md](../../scenarios/README.md).

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
vi /etc/shop/db.env            # BACKEND_HOST, hai mật khẩu database
./deploy/vm-db/install.sh
```

Script cài PostgreSQL 16, tạo database `shop` và `payments` cùng user riêng, bật `pg_stat_statements`, ghi log câu lệnh chậm hơn 1 giây, chỉ cho máy ứng dụng kết nối (pg_hba + firewalld), đặt lịch backup 02:30 hằng ngày (`/var/lib/pgsql/backups/shop`, giữ 7 bản).

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
| Truy vấn chậm | Máy CSDL: `/var/lib/pgsql/data/log/`; `SELECT * FROM pg_stat_statements ORDER BY total_exec_time DESC LIMIT 10` |
