# Vận hành: những gì đang chạy và cách bật/tắt

Bài tập gây sự cố có lệnh khôi phục: [fault-drills.md](fault-drills.md).

Tài liệu này liệt kê **mọi thành phần chạy nền** của hệ thống demo, nằm ở máy nào, và lệnh để kiểm tra, tắt, bật lại. Mọi lệnh chạy bằng `root` trên máy tương ứng, trừ phần tải giả lập.

Địa chỉ trong môi trường demo hiện tại:

| Máy | Hostname | IP | Vai trò |
|---|---|---|---|
| Web | `svfrt` | 192.168.50.64 | nginx + giao diện |
| Ứng dụng | `svbe` | 192.168.50.65 | Backend + cổng thanh toán |
| CSDL | `svdb` | 192.168.50.66 | PostgreSQL |
| Máy điều khiển | `control-plane` | 192.168.50.46 | Tải giả lập (k6), build, deploy |

## 1. Danh sách thành phần

| Máy | Thành phần | Kiểu chạy | Tên unit | Cổng | Tự chạy khi khởi động máy |
|---|---|---|---|---|---|
| svfrt | nginx | systemd service | `nginx` | 80 | Có |
| svbe | Backend cửa hàng | systemd service (Java) | `shop-backend` | 8080, 8081 (health) | Có |
| svbe | Docker Engine (Docker CE) | systemd service | `docker`, `containerd` | - | Có |
| svbe | Cổng thanh toán | **container Docker**, systemd chạy `docker run` | `shop-payment` (container cùng tên) | 127.0.0.1:8090 | Có |
| svbe | Chấm điểm rủi ro đơn hàng (Python 3.11, FastAPI) | **container Docker**, systemd chạy `docker run` | `shop-risk` (container cùng tên) | 127.0.0.1:8095 | Có |
| svdb | PostgreSQL 16 (`shop`, `payments`) | systemd service | `postgresql` | 5432 | Có |
| svdb | Backup database 02:30 hằng ngày | cron | `/etc/cron.d/shop-db-backup` | - | Có |
| svdb | Dọn đơn do tải tạo ra, quá 2 ngày, 03:00 hằng ngày | cron | `/etc/cron.d/shop-load-cleanup` | - | Có |
| control-plane | Tải giả lập k6 (2 người dùng ảo, ~55 request/phút, ~10 đơn/giờ) | systemd **user** service của `cp` | `shop-load` | - | Có (linger bật) |

Không có thành phần nào khác của hệ thống chạy nền.

## 2. Kiểm tra nhanh toàn hệ thống

```bash
# Từ control-plane
for h in 192.168.50.64 192.168.50.65 192.168.50.66; do
  ssh root@$h 'echo "== $(hostname)"; systemctl is-active nginx shop-backend shop-payment postgresql 2>/dev/null | paste -sd" "'
done
systemctl --user is-active shop-load
curl -s -o /dev/null -w '%{http_code}\n' http://192.168.50.64/api/site-config    # 200 là chạy
```

## 3. Từng thành phần

### nginx (svfrt)

```bash
systemctl status nginx
systemctl stop nginx        # tắt: trang web không truy cập được
systemctl start nginx
systemctl disable --now nginx   # tắt và không tự chạy khi khởi động lại máy
systemctl enable --now nginx
```

Cấu hình: `/etc/shop/web.env`, `/etc/nginx/conf.d/shop.conf` (sinh bởi `shop-render-nginx`). Log: `/var/log/nginx/`.

### shop-backend (svbe)

```bash
systemctl status shop-backend
systemctl stop shop-backend      # nginx sẽ trả 502 cho /api
systemctl start shop-backend     # mất khoảng 40-60 giây để sẵn sàng
curl -s http://127.0.0.1:8081/actuator/health
```

Cấu hình: `/etc/shop/app.env`. Log JSON: `/var/log/shop/backend.log`; log dạng chữ: `journalctl -u shop-backend -f`.

Cổng quản trị 8081 (chỉ mạng quản trị vào được; không có gì gọi định kỳ, `deploy.sh` chỉ gọi readiness lúc triển khai): `/actuator/health` (kèm `liveness`, `readiness`), `/actuator/info`, `/actuator/prometheus` (metric dạng Prometheus, không cần đăng nhập để công cụ thu thập đọc được).

### shop-payment (svbe, container Docker)

Cổng thanh toán chạy trong container Docker, image `shop-payment:current` (nền `registry.access.redhat.com/ubi9/openjdk-21-runtime`). Service systemd `shop-payment` (`/etc/systemd/system/shop-payment.service`) tạo container mới bằng `docker run` mỗi lần start và xóa khi stop, nên vẫn quản lý bằng `systemctl`.

```bash
systemctl status shop-payment
systemctl stop shop-payment      # dừng và xóa container; đơn thẻ thất bại, COD vẫn chạy
systemctl start shop-payment     # tạo lại container từ image :current
systemctl disable --now shop-payment   # tắt hẳn, không tự chạy khi khởi động máy
curl -s http://127.0.0.1:8090/actuator/health
docker ps                         # container shop-payment
docker logs -f shop-payment       # hoặc: journalctl -u shop-payment -f
docker images shop-payment        # :current (đang chạy), :prev (bản trước), các tag thời gian
```

| File | Nội dung |
|---|---|
| `/etc/systemd/system/shop-payment.service` | Lệnh `docker run`: image, cổng, volume log, biến môi trường |
| `/etc/shop/payment.env` | Biến môi trường của container, **sinh từ** `/etc/shop/app.env` bằng `shop-payment-env`. Sửa `app.env` rồi chạy `shop-payment-env && systemctl restart shop-payment` |
| `/var/log/shop-payment/payment.log` | Log JSON (thư mục mount vào container) |

Docker Engine: `systemctl status docker`. Docker CE cài từ repo `download.docker.com` (`/etc/yum.repos.d/docker-ce.repo`). Podman (có sẵn trên RHEL) vẫn còn nhưng không chạy container nào của hệ thống.

Vì sao Docker mà không phải Podman: RHEL 9.8 đi kèm crun 1.27, ngoài dải phiên bản mà công cụ giám sát hỗ trợ tự gắn vào container Podman (crun 0.17-1.15); container Docker (runc) thì được hỗ trợ.

### shop-risk (svbe, container Docker, Python)

Dịch vụ chấm điểm rủi ro: backend gọi khi khách đặt hàng (timeout 3 giây). **Phụ trợ**: tắt dịch vụ này thì đơn vẫn đặt được, chỉ không có điểm rủi ro.

```bash
systemctl status shop-risk
systemctl stop shop-risk          # đơn vẫn đặt được, backend ghi WARN "Risk service failed"
systemctl start shop-risk
curl -s http://127.0.0.1:8095/healthz
docker logs -f shop-risk          # mỗi đơn: "Scored order ... -> 70 HIGH ..." kèm rid (X-Request-Id)
docker images shop-risk           # :current, :prev, tag thời gian (deploy.sh risk)
```

| File | Nội dung |
|---|---|
| `/etc/systemd/system/shop-risk.service` | Lệnh `docker run` |
| `/etc/shop/risk.env` | Sinh từ `/etc/shop/app.env` bằng `shop-container-env` (`RISK_API_KEY`, phiên bản, `AUTOWRAPT_BOOTSTRAP` nếu có) |

Cấu hình phía backend trong `app.env`: `APP_RISK_URL` (để trống = không chấm điểm), `RISK_API_KEY`. Đơn rủi ro cao hiện nhãn "Cần kiểm tra" ở **Quản trị → Đơn hàng** (lọc được theo mức rủi ro).

### PostgreSQL (svdb)

```bash
systemctl status postgresql
systemctl stop postgresql        # toàn bộ API lỗi
systemctl start postgresql
runuser -u postgres -- psql -l
```

Cấu hình: `/etc/shop/db.env`, `/var/lib/pgsql/data/conf.d/shop.conf`. Log: `/var/lib/pgsql/data/log/`.

Backup: lịch ở `/etc/cron.d/shop-db-backup`, file ở `/var/lib/pgsql/backups/shop`. Tắt lịch backup: `mv /etc/cron.d/shop-db-backup /root/`. Chạy backup ngay: `ENV_FILE=/etc/shop/db.env /usr/local/bin/shop-db-backup`.

Dọn dữ liệu do tải tạo ra: mọi đơn của k6 có ghi chú `k6`. Lịch `/etc/cron.d/shop-load-cleanup` chạy `/usr/local/bin/shop-load-cleanup` lúc 03:00, xóa các đơn đó cũ hơn `LOAD_CLEANUP_DAYS` ngày (trong `/etc/shop/db.env`, hiện là 2) kèm sản phẩm trong đơn, lịch sử trạng thái, giao dịch ở database `payments`, rồi tính lại số đã bán và lượt dùng mã giảm giá. Nhật ký: `/var/log/shop-load-cleanup.log`.

```bash
ENV_FILE=/etc/shop/db.env /usr/local/bin/shop-load-cleanup 0    # xóa ngay mọi đơn của tải (0 = không giữ ngày nào)
mv /etc/cron.d/shop-load-cleanup /root/                          # tắt lịch dọn
```

### Tải giả lập k6 (control-plane, user `cp`)

Chạy dưới dạng systemd user service để có lưu lượng liên tục vào shop (các nhóm hành vi: [../../scenarios/README.md](../../scenarios/README.md)). File unit mẫu: [`load/shop-load.user.service`](../../load/shop-load.user.service).

```bash
systemctl --user status shop-load
systemctl --user stop shop-load        # dừng tải
systemctl --user start shop-load
systemctl --user disable --now shop-load   # dừng hẳn, không tự chạy lại
journalctl --user -u shop-load -f
```

| File | Nội dung |
|---|---|
| `~/.config/systemd/user/shop-load.service` | Unit chạy `k6 run <repo webshop-demo>/load/shop.js` (bản sao của `load/shop-load.user.service`) |
| `~/.config/shop-load/env` | `BASE_URL`, `PROFILE`, `VUS` (số người dùng ảo), `BUY_PERCENT` (tỷ lệ lượt mua hàng), `DURATION`, `ADMIN_PASSWORD` (chmod 600) |
| `~/.local/bin/k6` | k6 (bản tải từ GitHub releases) |

Mức tải: sửa `~/.config/shop-load/env` rồi `systemctl --user restart shop-load`.

| Mức | Cấu hình | Lưu lượng | Đơn hàng |
|---|---|---|---|
| Nền (mặc định) | `VUS=2`, `BUY_PERCENT=2` | ~55 request/phút | ~10/giờ |
| Buổi demo | `VUS=10`, `BUY_PERCENT=25` | ~300 request/phút | ~440/giờ |

Sau buổi demo nên trả về mức nền; đơn sinh ra sẽ được lịch dọn xóa sau 2 ngày.

`loginctl enable-linger cp` đã được bật để service chạy cả khi `cp` không đăng nhập; tắt bằng `loginctl disable-linger cp`.

Tải giả lập tạo đơn hàng thật trong database (ghi chú `k6`); nhóm quản trị trong kịch bản tự xử lý đơn và nhập thêm hàng cho size đã hết, lịch dọn trên svdb xóa đơn cũ, nên có thể chạy liên tục nhiều tuần.

## 4. Tắt toàn bộ demo

```bash
systemctl --user disable --now shop-load                                 # control-plane
ssh root@192.168.50.64 'systemctl disable --now nginx'
ssh root@192.168.50.65 'systemctl disable --now shop-backend shop-payment shop-risk'
ssh root@192.168.50.66 'systemctl disable --now postgresql; mv /etc/cron.d/shop-db-backup /etc/cron.d/shop-load-cleanup /root/ 2>/dev/null'
```

Bật lại theo thứ tự CSDL → ứng dụng → web → tải:

```bash
ssh root@192.168.50.66 'systemctl enable --now postgresql; mv /root/shop-db-backup /root/shop-load-cleanup /etc/cron.d/ 2>/dev/null'
ssh root@192.168.50.65 'systemctl enable --now shop-payment shop-risk shop-backend'
ssh root@192.168.50.64 'systemctl enable --now nginx'
systemctl --user enable --now shop-load
```

Dữ liệu, cấu hình và firewall không bị đụng tới khi tắt. `docker` vẫn chạy (không có container nào); tắt hẳn: `systemctl disable --now docker docker.socket containerd`.

## 5. Thành phần cũ (logistics) đã tắt

Trước Sải Bước, các máy chạy một ứng dụng logistics. Đã tắt và tắt tự khởi động, dữ liệu vẫn còn:

| Máy | Còn lại | Ghi chú |
|---|---|---|
| svfrt | `/root/logistics-nginx-backup/logistics.conf`, `/var/www/logistics` | Không còn được nginx nạp |
| svbe | Unit `logistics-backend` (disabled), `/opt/logistics` | |
| svdb | Database `logistics`, unit `minio` (disabled), `/var/lib/minio`, `/root/logistics-db-backup.cron.disabled` | Firewall còn rule cổng 9000 từ svbe, không có gì nghe ở cổng này |
