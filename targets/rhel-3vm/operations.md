# Vận hành: những gì đang chạy và cách bật/tắt

Bài tập gây sự cố có lệnh khôi phục: [fault-drills.md](fault-drills.md).

Tài liệu này liệt kê **mọi thành phần chạy nền** của hệ thống demo, nằm ở máy nào, và lệnh để kiểm tra, tắt, bật lại. Mọi lệnh chạy bằng `root` trên máy tương ứng, trừ phần tải giả lập.

Địa chỉ trong môi trường demo hiện tại:

| Máy | Hostname | IP | Vai trò |
|---|---|---|---|
| Web | `svfrt` | 192.168.50.64 | nginx + giao diện |
| Ứng dụng | `svbe` | 192.168.50.65 | Backend + cổng thanh toán |
| CSDL | `svdb` | 192.168.50.66 | PostgreSQL + hàng đợi Kafka |
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
| svdb | Hàng đợi đơn hàng: Apache Kafka 4.3 (KRaft, 1 node), topic `orders` | systemd service (Java) | `kafka` | 9092 (chỉ svbe), 9093 (127.0.0.1) | Có |
| svdb | Backup database 02:30 hằng ngày | cron | `/etc/cron.d/shop-db-backup` | - | Có |
| svdb | Dọn đơn do tải tạo ra, quá 2 ngày, 03:00 hằng ngày | cron | `/etc/cron.d/shop-load-cleanup` | - | Có |
| worker-1, worker-2 | Tải giả lập k6, mỗi worker một pod (mức tải: xem mục Tải giả lập) | Pod Kubernetes, điều khiển bằng `kubectl` từ control-plane | namespace `shop-loadgen`, deployment `shop-loadgen` | - | Có (Kubernetes tự chạy lại) |

Không có thành phần nào khác của hệ thống chạy nền.

## 2. Kiểm tra nhanh toàn hệ thống

```bash
# Từ control-plane
for h in 192.168.50.64 192.168.50.65 192.168.50.66; do
  ssh root@$h 'echo "== $(hostname)"; systemctl is-active nginx shop-backend shop-payment shop-risk postgresql kafka 2>/dev/null | paste -sd" "'
done
kubectl -n shop-loadgen get pods --no-headers
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

### Kafka (svdb)

Hàng đợi sự kiện đơn hàng. Backend gửi `ORDER_PLACED` vào topic `orders` (3 partition) sau mỗi đơn đặt thành công; consumer group `shop-warehouse` (chạy trong backend, đóng vai **kho**) đọc và đánh dấu đơn "Kho đã nhận". Cột **Kho** ở **Quản trị → Đơn hàng** cho thấy trạng thái; lag và số consumer hiện ở đầu trang **Mô phỏng sự cố**.

```bash
systemctl status kafka
systemctl stop kafka             # khách vẫn đặt được hàng; đơn mới bị đánh dấu "Không gửi được sang kho"
systemctl start kafka
K=/opt/kafka/current/bin
runuser -u kafka -- $K/kafka-consumer-groups.sh --bootstrap-server 127.0.0.1:9092 --describe --group shop-warehouse   # lag từng partition
runuser -u kafka -- $K/kafka-topics.sh --bootstrap-server 127.0.0.1:9092 --describe --topic orders
```

| File | Nội dung |
|---|---|
| `/etc/kafka/server.properties` | Cấu hình broker (sinh bởi `deploy/vm-db/kafka.sh`) |
| `/etc/systemd/system/kafka.service` | Heap 512 MB (`KAFKA_HEAP` trong `db.env`) |
| `/var/lib/kafka/data` | Dữ liệu; giữ 72 giờ (`KAFKA_RETENTION_HOURS`) |
| `/var/log/kafka/server.log` | Log broker |

Firewall: cổng 9092 chỉ mở cho svbe. Không có xác thực (PLAINTEXT), chỉ dùng trong mạng nội bộ. Phía backend: `APP_KAFKA_BOOTSTRAP=192.168.50.66:9092` trong `app.env`; để trống là tắt hàng đợi (đơn không có trạng thái kho, kịch bản `KAFKA_*` không bật được). Đơn của tải bị lịch dọn xóa trước khi kho nhận (khi consumer chết lâu) thì kho bỏ qua sự kiện đó.

### Tải giả lập k6 (cụm Kubernetes, từ control-plane, user `cp`)

Tải giả lập là thành phần `loadgen/` của repo `webshop`; cách build image và các file Kubernetes được mô tả trong [loadgen/README.md](https://github.com/vnkmasc/webshop/blob/main/loadgen/README.md). Ở môi trường này tải chạy trên cụm Kubernetes mà control-plane (192.168.50.46) là master: 2 pod, mỗi pod một worker (worker-1, worker-2). Image nằm trên Harbor của cụm.

| Thành phần | Giá trị |
|---|---|
| Registry | Harbor `harbor.mcredit.local:30003`, project `library` (public, node kéo không cần secret) |
| Image | `harbor.mcredit.local:30003/library/shop-loadgen:<commit>` |
| Namespace / Deployment | `shop-loadgen` / `shop-loadgen`, 2 replica |
| ConfigMap `shop-loadgen` | Mức tải **cho mỗi pod**: `VUS`, `BUY_PERCENT`, `ORDERS_PER_MIN`, `CARD_PERCENT`, `BASE_URL`, `PROFILE`, `DURATION` |
| Secret `shop-loadgen` | `ADMIN_PASSWORD` (lấy từ `~/.config/shop-load/env` lúc triển khai) |

```bash
kubectl -n shop-loadgen get pods -o wide                        # 2 pod Running, mỗi worker một pod
kubectl -n shop-loadgen logs -f deploy/shop-loadgen             # chỉ in lỗi (k6 chạy --quiet)
kubectl -n shop-loadgen scale deploy/shop-loadgen --replicas=0  # dừng tải
kubectl -n shop-loadgen scale deploy/shop-loadgen --replicas=2  # chạy lại
```

Đổi mức tải (giá trị cho mỗi pod, tổng gấp đôi):

```bash
# mức demo: tổng 10 người dùng ảo, 10 đơn/phút
kubectl -n shop-loadgen patch cm shop-loadgen --type merge -p '{"data":{"VUS":"5","BUY_PERCENT":"25","ORDERS_PER_MIN":"5"}}' && kubectl -n shop-loadgen rollout restart deploy/shop-loadgen
# mức nền: tổng 2 người dùng ảo, 2 đơn/phút
kubectl -n shop-loadgen patch cm shop-loadgen --type merge -p '{"data":{"VUS":"1","BUY_PERCENT":"2","ORDERS_PER_MIN":"1"}}' && kubectl -n shop-loadgen rollout restart deploy/shop-loadgen
```

| Mức | Mỗi pod | Tổng (2 pod) | Đơn hàng |
|---|---|---|---|
| Nền | `VUS=1`, `BUY_PERCENT=2`, `ORDERS_PER_MIN=1` | ~60 request/phút | ~130/giờ |
| Buổi demo | `VUS=5`, `BUY_PERCENT=25`, `ORDERS_PER_MIN=5` | ~350 request/phút | ~1000/giờ (cổng thanh toán ~8 request/phút) |

Sửa `shop.js` xong (repo `webshop`, đã commit) thì build, đẩy image và triển khai lại:

```bash
cd ~/promptdo/webshop
podman login harbor.mcredit.local:30003                                   # một lần; podman tin CA của Harbor qua /etc/containers/certs.d
scripts/build-images.sh -p harbor.mcredit.local:30003/library loadgen
set -a; . ~/.config/shop-load/env; set +a
loadgen/k8s/deploy.sh "$BASE_URL" harbor.mcredit.local:30003/library/shop-loadgen:$(git rev-parse --short HEAD)
```

Mức tải đã chỉnh được giữ qua các lần triển khai lại. Service systemd cũ `shop-load` của `cp` đã dừng và disable; **không chạy song song** với pod, tải sẽ bị cộng dồn.

Sau buổi demo nên trả về mức nền; đơn sinh ra sẽ được lịch dọn xóa sau 2 ngày.

Tải giả lập tạo đơn hàng thật trong database (ghi chú `k6`); nhóm quản trị trong kịch bản tự xử lý đơn và nhập thêm hàng cho size đã hết, lịch dọn trên svdb xóa đơn cũ, nên có thể chạy liên tục nhiều tuần.

## 4. Tắt toàn bộ demo

```bash
kubectl -n shop-loadgen scale deploy/shop-loadgen --replicas=0         # tải (từ control-plane)
ssh root@192.168.50.64 'systemctl disable --now nginx'
ssh root@192.168.50.65 'systemctl disable --now shop-backend shop-payment shop-risk'
ssh root@192.168.50.66 'systemctl disable --now kafka postgresql; mv /etc/cron.d/shop-db-backup /etc/cron.d/shop-load-cleanup /root/ 2>/dev/null'
```

Bật lại theo thứ tự CSDL → ứng dụng → web → tải:

```bash
ssh root@192.168.50.66 'systemctl enable --now postgresql kafka; mv /root/shop-db-backup /root/shop-load-cleanup /etc/cron.d/ 2>/dev/null'
ssh root@192.168.50.65 'systemctl enable --now shop-payment shop-risk shop-backend'
ssh root@192.168.50.64 'systemctl enable --now nginx'
kubectl -n shop-loadgen scale deploy/shop-loadgen --replicas=2
```

Dữ liệu, cấu hình và firewall không bị đụng tới khi tắt. `docker` vẫn chạy (không có container nào); tắt hẳn: `systemctl disable --now docker docker.socket containerd`.

## 5. Thành phần cũ (logistics) đã tắt

Trước Sải Bước, các máy chạy một ứng dụng logistics. Đã tắt và tắt tự khởi động, dữ liệu vẫn còn:

| Máy | Còn lại | Ghi chú |
|---|---|---|
| svfrt | `/root/logistics-nginx-backup/logistics.conf`, `/var/www/logistics` | Không còn được nginx nạp |
| svbe | Unit `logistics-backend` (disabled), `/opt/logistics` | |
| svdb | Database `logistics`, unit `minio` (disabled), `/var/lib/minio`, `/root/logistics-db-backup.cron.disabled` | Firewall còn rule cổng 9000 từ svbe, không có gì nghe ở cổng này |
