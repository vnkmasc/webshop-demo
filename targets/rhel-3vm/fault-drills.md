# Bài tập sự cố: lệnh để tự thực hiện (target rhel-3vm)

Mỗi bài gồm: **lệnh gây sự cố**, **hiện tượng** người dùng và hệ thống thấy, **khôi phục**, **kiểm tra đã ổn**. Lệnh chạy từ máy điều khiển (`control-plane`, user `cp`) qua `ssh root@...`, hoặc bỏ phần `ssh` nếu đang đứng trên máy đó.

Không phụ thuộc công cụ giám sát nào; cột "nơi thấy rõ" chỉ nêu loại tín hiệu (thời gian phản hồi, lỗi, tài nguyên máy, tiến trình...).

> **Trước khi tập các bài firewall/mạng (2.2, 2.7, 3.7, 4.2), đảm bảo mở được console của VM trên hypervisor**: nếu lỡ mất SSH, đó là đường duy nhất để khôi phục.
>
> Chỉ làm trên môi trường demo. Mỗi lần **một** bài, để 15-30 phút cho công cụ giám sát kịp phát hiện, khôi phục xong rồi mới sang bài khác. Các bài có rủi ro mất kết nối dùng dạng **tự khôi phục sau N giây**.

## 0. Chuẩn bị

```bash
# Biến dùng trong cả tài liệu
WEB=192.168.50.64    # svfrt: nginx
APP=192.168.50.65    # svbe: shop-backend, shop-payment (Docker)
DB=192.168.50.66     # svdb: PostgreSQL, Kafka
IFACE=ens33          # card mạng trên các VM

# Kiểm tra nhanh toàn hệ thống (dùng lại sau mỗi bài)
check() {
  echo "web       : $(curl -s -o /dev/null -w '%{http_code} %{time_total}s' http://$WEB/api/site-config)"
  echo "products  : $(curl -s -o /dev/null -w '%{http_code} %{time_total}s' "http://$WEB/api/products?pageSize=24")"
  echo "backend   : $(ssh root@$APP 'curl -s http://127.0.0.1:8081/actuator/health/readiness')"
  echo "payment   : $(ssh root@$APP 'curl -s http://127.0.0.1:8090/actuator/health/readiness')"
  echo "postgresql: $(ssh root@$DB 'systemctl is-active postgresql')"
  echo "kafka     : $(ssh root@$DB 'systemctl is-active kafka'), $(curl -s http://$APP:8081/actuator/prometheus | grep -E '^shop_events_(lag|consumers)' | sed -E 's/\{[^}]*\}//' | paste -sd' ')"
}
check
```

Tải nền phải đang chạy, nếu không sự cố không ảnh hưởng tới ai (xem [../../scenarios/README.md](../../scenarios/README.md#4-điều-kiện-để-công-cụ-giám-sát-mở-cảnh-báo)). Khi tập, nên tăng lên mức demo rồi trả lại sau:

```bash
sed -i 's/^VUS=.*/VUS=10/; s/^BUY_PERCENT=.*/BUY_PERCENT=25/; s/^ORDERS_PER_MIN=.*/ORDERS_PER_MIN=10/' ~/.config/shop-load/env && systemctl --user restart shop-load
# sau buổi tập:
sed -i 's/^VUS=.*/VUS=2/; s/^BUY_PERCENT=.*/BUY_PERCENT=2/; s/^ORDERS_PER_MIN=.*/ORDERS_PER_MIN=1/' ~/.config/shop-load/env && systemctl --user restart shop-load
```

Một số bài về mạng cần module `sch_netem` (giả lập trễ/mất gói), không có sẵn trên RHEL minimal. Cài một lần trên máy cần dùng (đã cài sẵn trên svdb):

```bash
ssh root@$APP 'dnf install -y kernel-modules-extra-$(uname -r) && modprobe sch_netem'
```

## 1. Sự cố trong ứng dụng (qua API, không đụng hạ tầng)

Giống trang **Quản trị → Mô phỏng sự cố**, nhưng bằng dòng lệnh:

```bash
ADMIN_PASSWORD='<APP_ADMIN_PASSWORD>'     # trong /etc/shop/app.env trên svbe
TOKEN=$(curl -s -X POST -H 'Content-Type: application/json' \
  -d "{\"email\":\"admin@saibuoc.vn\",\"password\":\"$ADMIN_PASSWORD\"}" http://$WEB/api/auth/login | jq -r .data.accessToken)
sim() {  # sim SCENARIO '{"active":true,...}'
  curl -s -X PUT -H "Authorization: Bearer $TOKEN" -H 'Content-Type: application/json' -d "$2" \
    http://$WEB/api/admin/simulation/$1 | jq -c '.data | {scenario, active, expiresAt}'
}
gateway() {  # gateway '{"baseLatencyMs":250,"extraLatencyMs":0,"errorRatePercent":0,"declineRatePercent":3,"outage":false}'
  curl -s -X PUT -H "Authorization: Bearer $TOKEN" -H 'Content-Type: application/json' -d "$1" \
    http://$WEB/api/admin/payment-gateway | jq -c '.data | del(.lastHour)'
}
status() { curl -s -H "Authorization: Bearer $TOKEN" http://$WEB/api/admin/simulation | jq -c '.data.scenarios[] | select(.active)'; }
```

| Bài | Bật | Tắt |
|---|---|---|
| SQL chậm 3 giây ở danh sách/tìm kiếm | `sim SLOW_SQL '{"active":true,"durationMinutes":30,"params":{"sleepMs":3000}}'` | `sim SLOW_SQL '{"active":false}'` |
| Lỗi 500 ở 30% request đặt hàng | `sim HTTP_ERROR '{"active":true,"durationMinutes":30,"params":{"target":"CHECKOUT","ratePercent":30}}'` | `sim HTTP_ERROR '{"active":false}'` |
| API danh mục chậm 1-3 giây | `sim LATENCY '{"active":true,"durationMinutes":30,"params":{"target":"CATALOG","minMs":1000,"maxMs":3000}}'` | `sim LATENCY '{"active":false}'` |
| Truy vấn N+1 | `sim N_PLUS_ONE '{"active":true,"durationMinutes":30}'` | `sim N_PLUS_ONE '{"active":false}'` |
| Cạn connection pool | `sim POOL_EXHAUSTION '{"active":true,"durationMinutes":20,"params":{"target":"ALL","holdMs":3000,"ratePercent":40}}'` | `sim POOL_EXHAUSTION '{"active":false}'` |
| CPU cao ở trang sản phẩm | `sim HIGH_CPU '{"active":true,"durationMinutes":20,"params":{"cpuMs":4000}}'` | `sim HIGH_CPU '{"active":false}'` |
| Rò bộ nhớ | `sim MEMORY_LEAK '{"active":true,"durationMinutes":30,"params":{"kbPerRequest":512,"capMb":1500}}'` | `sim MEMORY_LEAK '{"active":false}'` |
| Lỗi JavaScript ở nút "Thêm vào giỏ" (cần mở trình duyệt thật) | `sim FRONTEND_ERROR '{"active":true,"durationMinutes":30}'` | `sim FRONTEND_ERROR '{"active":false}'` |
| Ngân hàng chậm +4 giây | `gateway '{"baseLatencyMs":250,"extraLatencyMs":4000,"errorRatePercent":0,"declineRatePercent":3,"outage":false}'` | `gateway '{"baseLatencyMs":250,"extraLatencyMs":0,"errorRatePercent":0,"declineRatePercent":3,"outage":false}'` |
| Cổng thanh toán quá thời gian chờ (+10 giây) | `gateway '{"baseLatencyMs":250,"extraLatencyMs":10000,"errorRatePercent":0,"declineRatePercent":3,"outage":false}'` | như trên |
| Cổng thanh toán lỗi 30% | `gateway '{"baseLatencyMs":250,"extraLatencyMs":0,"errorRatePercent":30,"declineRatePercent":3,"outage":false}'` | như trên |
| Cổng thanh toán ngừng hoạt động | `gateway '{"baseLatencyMs":250,"extraLatencyMs":0,"errorRatePercent":0,"declineRatePercent":3,"outage":true}'` | như trên |
| Lỗi nghiệp vụ trong body: HTTP 200, `responseCode` 99 ở 40% giao dịch thẻ | `sim PAYMENT_BUSINESS_ERROR '{"active":true,"durationMinutes":30,"params":{"code":"99","percent":40}}'` | `sim PAYMENT_BUSINESS_ERROR '{"active":false}'` |
| Mã HTTP lạ: 423 ở 40% request đặt hàng | `sim ODD_STATUS '{"active":true,"durationMinutes":30,"params":{"code":423,"target":"CHECKOUT","percent":40}}'` | `sim ODD_STATUS '{"active":false}'` |
| Readiness hỏng (endpoint readiness báo DOWN) | `sim READINESS_FAIL '{"active":true,"durationMinutes":10}'` | `sim READINESS_FAIL '{"active":false}'` |
| Lộ dữ liệu nhạy cảm giả | `sim EMIT_PII '{"active":true,"durationMinutes":30}'` | `sim EMIT_PII '{"active":false}'` |
| Dịch vụ rủi ro (Python) chậm 2 giây | `sim RISK_SLOW '{"active":true,"durationMinutes":30,"params":{"delayMs":2000}}'` | `sim RISK_SLOW '{"active":false}'` |
| Dịch vụ rủi ro lỗi 30% | `sim RISK_ERROR '{"active":true,"durationMinutes":30,"params":{"percent":30}}'` | `sim RISK_ERROR '{"active":false}'` |
| Dịch vụ rủi ro quá thời gian chờ (5 giây > timeout 3 giây) | `sim RISK_TIMEOUT '{"active":true,"durationMinutes":30,"params":{"delayMs":5000}}'` | `sim RISK_TIMEOUT '{"active":false}'` |
| Hàng đợi xử lý chậm (15 giây mỗi đơn; cần tải mức demo để lag dồn) | `sim KAFKA_SLOW_CONSUMER '{"active":true,"durationMinutes":30,"params":{"delayMs":15000}}'` | `sim KAFKA_SLOW_CONSUMER '{"active":false}'` |
| Consumer hàng đợi chết (lag tăng đều, group không còn thành viên) | `sim KAFKA_CONSUMER_DEAD '{"active":true,"durationMinutes":30}'` | `sim KAFKA_CONSUMER_DEAD '{"active":false}'` |
| Nổ cardinality metric (tối đa 5.000 series) | `sim METRIC_CARDINALITY '{"active":true,"durationMinutes":30,"params":{"perRequest":10}}'` | `sim METRIC_CARDINALITY '{"active":false}'` |

Kiểm tra các kịch bản mới:

```bash
# Lỗi nghiệp vụ: gọi thẳng cổng thanh toán, thấy HTTP 200 + X-Response-Code + body responseCode
ssh root@$APP 'KEY=$(grep ^PAYMENT_API_KEY /etc/shop/app.env | cut -d= -f2); curl -s -i -X POST -H "Authorization: Bearer $KEY" -H "Content-Type: application/json" http://127.0.0.1:8090/api/payments/charge -d "{\"orderCode\":\"TEST\",\"amount\":100000,\"card\":{\"number\":\"4111111111111111\",\"holder\":\"T\",\"expiry\":\"12/30\",\"cvv\":\"123\"}}" | grep -E "^HTTP|^X-Response-Code|^\{"'
# Mã HTTP lạ
curl -s -i -X POST -H 'Content-Type: application/json' http://$WEB/api/orders -d '{}' | grep -E '^HTTP|^Retry-After|^\{'
# Readiness: backend DOWN nhưng liveness UP
ssh root@$APP 'curl -s http://127.0.0.1:8081/actuator/health/readiness | head -c 80; echo; curl -s http://127.0.0.1:8081/actuator/health/liveness'
# Dữ liệu nhạy cảm giả trong log
ssh root@$APP 'grep payment.card_number /var/log/shop/backend.log | tail -1 | jq -c "{message, \"payment.card_number\"}"'
# Số series metric
curl -s http://$APP:8081/actuator/prometheus | grep -c '^shop_request_tagged_total'
# Hàng đợi: lag và số consumer (backend đo mỗi 10 giây), và cùng số liệu đó từ phía Kafka
curl -s http://$APP:8081/actuator/prometheus | grep -E '^shop_events_(lag|consumers)'
ssh root@$DB 'runuser -u kafka -- /opt/kafka/current/bin/kafka-consumer-groups.sh --bootstrap-server 127.0.0.1:9092 --describe --group shop-warehouse'
```

`KAFKA_CONSUMER_DEAD` có hiệu lực sau tối đa ~5 giây, và consumer đọc lại sau tối đa ~5 giây khi tắt kịch bản. Ở tải nền (~10 đơn/giờ), lag chỉ tăng vài đơn; muốn thấy rõ đường lag đi lên, dùng tải mức demo (~7 đơn/phút).

Xem kịch bản đang bật: `status`. Ý nghĩa từng kịch bản: [../../scenarios/README.md](../../scenarios/README.md).

## 2. Máy CSDL (svdb)

### 2.1 Dừng PostgreSQL

```bash
ssh root@$DB 'systemctl stop postgresql'
```
- **Hiện tượng:** mọi trang có dữ liệu lỗi 500 sau ~5 giây (chờ lấy kết nối), `/actuator/health/readiness` của backend và payment chuyển `DOWN`. Tiến trình `postgres` biến mất trên svdb.
- **Khôi phục:** `ssh root@$DB 'systemctl start postgresql'`. Backend và payment tự kết nối lại, không cần khởi động lại.
- **Kiểm tra:** `check` (readiness `UP` sau vài giây).

### 2.2 Mất kết nối mạng từ máy ứng dụng tới CSDL (timeout, khác với "từ chối")

Chặn (DROP) gói tin từ svbe tới cổng 5432, rồi cắt các kết nối đang mở để pool phải kết nối lại. Tự khôi phục sau 10 phút:

```bash
ssh root@$DB "firewall-cmd --add-rich-rule='rule family=\"ipv4\" source address=\"$APP\" port port=\"5432\" protocol=\"tcp\" drop' --timeout=600 \
  && runuser -u postgres -- psql -qc \"SELECT pg_terminate_backend(pid) FROM pg_stat_activity WHERE datname IN ('shop','payments') AND pid <> pg_backend_pid()\""
```
- **Hiện tượng:** request treo ~5 giây rồi lỗi 500 (`Connection is not available, request timed out`), readiness DOWN; PostgreSQL vẫn chạy bình thường. Đây là kiểu "dịch vụ phụ thuộc không phản hồi" chứ không phải "dịch vụ chết".
- **Khôi phục sớm** (gỡ đúng rule tạm đó):
  ```bash
  ssh root@$DB "firewall-cmd --remove-rich-rule='rule family=\"ipv4\" source address=\"$APP\" port port=\"5432\" protocol=\"tcp\" drop'"
  ```
- **Không dùng `firewall-cmd --reload` khi đang có rule tạm (`--timeout`)**: firewalld có thể lỗi giữa chừng (`dictionary changed size during iteration`) và chặn toàn bộ máy, kể cả SSH; khi đó chỉ khôi phục được qua console của VM bằng `systemctl restart firewalld`.
- **Kiểm tra:** `check`.

### 2.3 Khóa bảng (giao dịch giữ lock lâu)

Giữ khóa độc quyền trên bảng size/tồn kho trong 120 giây:

```bash
ssh root@$DB "runuser -u postgres -- psql -d shop -c 'BEGIN; LOCK TABLE product_variants IN ACCESS EXCLUSIVE MODE; SELECT pg_sleep(120); COMMIT;'"
```
- **Hiện tượng:** danh sách sản phẩm, trang sản phẩm, giỏ hàng, đặt hàng đều đứng chờ; CPU database thấp nhưng thời gian truy vấn rất cao (chờ lock); có thể kéo theo cạn connection pool.
- **Khôi phục:** tự hết sau 120 giây, hoặc Ctrl+C lệnh trên.
- **Xem ai đang chờ:** `ssh root@$DB "runuser -u postgres -- psql -d shop -c \"SELECT pid, wait_event_type, state, left(query,60) FROM pg_stat_activity WHERE datname='shop'\""`

### 2.4 Cắt các kết nối đang mở

```bash
ssh root@$DB "runuser -u postgres -- psql -qc \"SELECT pg_terminate_backend(pid) FROM pg_stat_activity WHERE datname IN ('shop','payments') AND pid <> pg_backend_pid()\""
```
- **Hiện tượng:** vài request đang chạy lỗi ngay lúc đó, sau đó pool tự kết nối lại. Sự cố thoáng qua, có log lỗi.

### 2.5 CPU database bão hòa (truy vấn nặng từ bên ngoài ứng dụng)

Chạy 4 truy vấn nặng song song (svdb có 4 vCPU), mỗi truy vấn tự dừng sau 5 phút:

```bash
ssh root@$DB 'for i in 1 2 3 4; do runuser -u postgres -- psql -d shop -qc "SET statement_timeout = '"'"'5min'"'"'; SELECT count(*) FROM generate_series(1, 1e12)" >/dev/null 2>&1 & done'
```
- **Hiện tượng:** CPU svdb ~100%, truy vấn của shop chậm lại; nguyên nhân là tiến trình `postgres` chạy câu lệnh không thuộc ứng dụng.
- **Khôi phục sớm:** `ssh root@$DB "runuser -u postgres -- psql -qc \"SELECT pg_cancel_backend(pid) FROM pg_stat_activity WHERE query LIKE '%generate_series(1, 1e12)%' AND pid <> pg_backend_pid()\""`

### 2.6 Đầy ổ đĩa

Lấp ổ `/` đến khi chỉ còn ~2 GB trống:

```bash
ssh root@$DB 'fallocate -l $(( $(df --output=avail -BG / | tail -1 | tr -dc 0-9) - 2 ))G /var/tmp/disk-fill.img && df -h /'
```
- **Hiện tượng:** cảnh báo dung lượng đĩa thấp trên svdb (khoảng 97% đầy). Shop vẫn chạy cho tới khi hết hẳn chỗ.
- **Khôi phục (đừng quên):** `ssh root@$DB 'rm -f /var/tmp/disk-fill.img && df -h /'`
- Không lấp tới 100%: PostgreSQL sẽ dừng ghi và có thể tự tắt.

### 2.7 Mạng chậm / mất gói giữa ứng dụng và CSDL

Thêm trễ 100 ms (±20 ms) cho mọi gói tin ra khỏi svdb, tự gỡ sau 15 phút (SSH vào svdb cũng chậm theo):

```bash
ssh root@$DB "modprobe sch_netem && nohup sh -c 'tc qdisc add dev $IFACE root netem delay 100ms 20ms && sleep 900; tc qdisc del dev $IFACE root' >/dev/null 2>&1 &"
```
- **Hiện tượng:** mỗi câu SQL chậm thêm ~100 ms, request nhiều câu SQL (danh sách sản phẩm, đặt hàng) chậm gấp bội; CPU mọi máy vẫn thấp, nguyên nhân nằm ở mạng.
- Biến thể mất gói 5%: thay `delay 100ms 20ms` bằng `loss 5%` (kết nối chập chờn, thỉnh thoảng timeout).
- **Khôi phục sớm:** `ssh root@$DB "tc qdisc del dev $IFACE root"`
- **Kiểm tra:** `ssh root@$DB "tc qdisc show dev $IFACE"` phải không còn `netem`.

### 2.8 Dừng Kafka

```bash
ssh root@$DB 'systemctl stop kafka'
```
- **Hiện tượng:** khách vẫn đặt hàng bình thường; sau ~10 giây backend ghi ERROR `Order event ORDER_PLACED ... could not be sent to the queue`, đơn mới có trạng thái kho **Không gửi được sang kho**. Metric `shop_events_lag`, `shop_events_consumers` thành `NaN`; trang Mô phỏng sự cố hiện "Hàng đợi: không đo được". Consumer ghi WARN mất kết nối tới broker.
- **Khôi phục:** `ssh root@$DB 'systemctl start kafka'` (~15 giây). Producer và consumer tự kết nối lại. Các đơn đặt lúc Kafka dừng **không được gửi lại**, giữ nguyên "Không gửi được sang kho".

### 2.9 Kafka chết đột ngột (kill -9), systemd tự dựng lại

```bash
ssh root@$DB 'systemctl kill -s KILL kafka'
```
- **Hiện tượng:** tiến trình Kafka mất rồi xuất hiện lại sau ~10 giây (`RestartSec=10`); số lần khởi động lại: `systemctl show kafka -p NRestarts`. Metric hàng đợi về số thật sau ~30-45 giây.
- **Khôi phục:** tự động.

## 3. Máy ứng dụng (svbe)

### 3.1 Backend chết đột ngột (kill -9), systemd tự dựng lại

```bash
ssh root@$APP 'kill -9 $(pgrep -f shop-backend.jar)'
```
- **Hiện tượng:** nginx trả 502 khoảng 40-60 giây (thời gian Spring Boot khởi động lại); systemd ghi "Main process exited, status=9/KILL" rồi tự khởi động lại; tiến trình Java mới có PID khác.
- **Khôi phục:** tự động. **Kiểm tra:** `check`; `ssh root@$APP 'systemctl show shop-backend -p NRestarts'`.

### 3.2 Dừng backend (sự cố có chủ đích, không tự lên)

```bash
ssh root@$APP 'systemctl stop shop-backend'
```
- **Hiện tượng:** toàn bộ `/api` trả 502 từ nginx; trang web vẫn tải được nhưng không có dữ liệu.
- **Khôi phục:** `ssh root@$APP 'systemctl start shop-backend'` (sẵn sàng sau ~40-60 giây).

### 3.3 Container cổng thanh toán chết, systemd tự dựng lại

```bash
ssh root@$APP 'docker kill shop-payment'
```
- **Hiện tượng:** thanh toán thẻ lỗi khoảng 25 giây ("Cổng thanh toán đang gặp sự cố"), COD vẫn đặt được; container mới được tạo (`docker ps` thấy "Up vài giây").
- **Khôi phục:** tự động. **Kiểm tra:** `ssh root@$APP 'docker ps; systemctl show shop-payment -p NRestarts'`.

### 3.4 Dừng cổng thanh toán

```bash
ssh root@$APP 'systemctl stop shop-payment'
```
- **Hiện tượng:** mọi đơn thẻ thất bại ngay (kết nối bị từ chối), đơn chuyển "Thanh toán thất bại", tồn kho được hoàn; COD bình thường. Trang **Quản trị → Cổng thanh toán** báo không kết nối được.
- **Khôi phục:** `ssh root@$APP 'systemctl start shop-payment'` (~25 giây).

### 3.5a Dừng dịch vụ chấm điểm rủi ro (phụ trợ)

```bash
ssh root@$APP 'systemctl stop shop-risk'
```
- **Hiện tượng:** đơn vẫn đặt được bình thường nhưng không có điểm rủi ro; backend ghi WARN `Risk service failed ... Connection refused`; call sang dịch vụ Python lỗi trên trace.
- **Khôi phục:** `ssh root@$APP 'systemctl start shop-risk'`

### 3.5 CPU máy ứng dụng bão hòa (tiến trình khác giành CPU)

Mỗi vCPU một tiến trình `yes`, tự dừng sau 10 phút:

```bash
ssh root@$APP 'for i in $(seq $(nproc)); do nohup timeout 600 yes >/dev/null 2>&1 & done'
```
- **Hiện tượng:** CPU svbe 100%, shop chậm dù không có lỗi; nguyên nhân là tiến trình `yes` không thuộc ứng dụng.
- **Khôi phục sớm:** `ssh root@$APP 'pkill -x yes'`

### 3.6 Thiếu bộ nhớ trên máy ứng dụng

Một tiến trình chiếm 3 GB RAM trong 5 phút (svbe có 7 GB, backend dùng tối đa 2 GB heap):

```bash
ssh root@$APP 'nohup timeout 300 python3 -c "a = bytearray(3 * 1024**3); import time; time.sleep(300)" >/dev/null 2>&1 &'
```
- **Hiện tượng:** RAM trống của svbe giảm mạnh, có thể bắt đầu dùng swap, GC của Java nhiều hơn.
- Đừng tăng quá 4 GB: hệ điều hành có thể kích hoạt OOM killer và giết tiến trình Java.
- **Khôi phục sớm:** `ssh root@$APP 'pkill -f "bytearray(3"'`

### 3.7 Mạng chậm giữa backend và mọi thứ phía sau

Cần cài `sch_netem` trên svbe trước (mục 0). Trễ 150 ms cho mọi gói tin ra khỏi svbe, tự gỡ sau 15 phút:

```bash
ssh root@$APP "modprobe sch_netem && nohup sh -c 'tc qdisc add dev $IFACE root netem delay 150ms && sleep 900; tc qdisc del dev $IFACE root' >/dev/null 2>&1 &"
```
- **Hiện tượng:** mọi API chậm (cả phản hồi về nginx lẫn truy vấn tới database).
- **Khôi phục sớm:** `ssh root@$APP "tc qdisc del dev $IFACE root"`

## 4. Máy web (svfrt)

### 4.1 Dừng nginx

```bash
ssh root@$WEB 'systemctl stop nginx'
```
- **Hiện tượng:** trang web không truy cập được (connection refused); backend vẫn khỏe nhưng không nhận request nào, tải giả lập báo lỗi kết nối.
- **Khôi phục:** `ssh root@$WEB 'systemctl start nginx'`

### 4.2 nginx không tới được backend (504)

Chặn kết nối mới từ svfrt tới cổng 8080 của svbe (tự gỡ sau 10 phút), rồi khởi động lại nginx để bỏ các kết nối keepalive cũ:

```bash
ssh root@$APP "firewall-cmd --add-rich-rule='rule family=\"ipv4\" source address=\"$WEB\" port port=\"8080\" protocol=\"tcp\" drop' --timeout=600" \
  && ssh root@$WEB 'systemctl restart nginx'
```
- **Hiện tượng:** trang tĩnh vẫn tải, mọi `/api` chờ 5 giây rồi trả 504 Gateway Timeout; backend khỏe nhưng không thấy request nào.
- **Khôi phục sớm** (gỡ đúng rule tạm, không dùng `--reload`):
  ```bash
  ssh root@$APP "firewall-cmd --remove-rich-rule='rule family=\"ipv4\" source address=\"$WEB\" port port=\"8080\" protocol=\"tcp\" drop'"
  ```

## 5. Triển khai

Lệnh chạy trên svbe, trong thư mục gói phát hành (`/root/shop-<version>`).

### 5.1 Triển khai lại (sự kiện deployment, vài chục giây gián đoạn)

```bash
ssh root@$APP 'cd /root/shop-1.0.0 && ./deploy/vm-app/deploy.sh backend backend/shop-backend.jar'
```

### 5.2 Bản phát hành lỗi và tự quay lại

Đưa một "jar" hỏng lên; health không lên được, script tự quay về bản trước sau 60 giây:

```bash
ssh root@$APP 'echo "not a jar" > /tmp/broken.jar && cd /root/shop-1.0.0 && WAIT_SECONDS=60 ./deploy/vm-app/deploy.sh backend /tmp/broken.jar'
```
- **Hiện tượng:** ~2 phút 502 (60 giây chờ + khởi động lại bản cũ); log `Error: Invalid or corrupt jarfile`, systemd khởi động lại liên tục; cuối cùng script báo "Rolled back successfully" và "Deployment failed".
- **Kiểm tra:** `check`; jar đang chạy là bản cũ (`ls -la /opt/shop/backend/`).

Tương tự cho cổng thanh toán (quay về image `:prev`): `WAIT_SECONDS=60 ./deploy/vm-app/deploy.sh payment /tmp/broken.jar`.

## 6. Khôi phục tất cả

Khi không chắc còn gì đang bật (không dùng `firewall-cmd --reload`, xem mục 2.2):

```bash
# Ứng dụng: tắt mọi kịch bản và đưa cổng thanh toán về bình thường (cần TOKEN ở mục 1)
for s in LATENCY HTTP_ERROR SLOW_SQL N_PLUS_ONE POOL_EXHAUSTION HIGH_CPU MEMORY_LEAK FRONTEND_ERROR \
         PAYMENT_BUSINESS_ERROR ODD_STATUS READINESS_FAIL EMIT_PII METRIC_CARDINALITY \
         RISK_SLOW RISK_ERROR RISK_TIMEOUT KAFKA_SLOW_CONSUMER KAFKA_CONSUMER_DEAD; do sim $s '{"active":false}'; done
gateway '{"baseLatencyMs":250,"extraLatencyMs":0,"errorRatePercent":0,"declineRatePercent":3,"outage":false}'

# Hạ tầng
ssh root@$DB  "firewall-cmd --remove-rich-rule='rule family=\"ipv4\" source address=\"$APP\" port port=\"5432\" protocol=\"tcp\" drop' 2>/dev/null; tc qdisc del dev $IFACE root 2>/dev/null; rm -f /var/tmp/disk-fill.img; systemctl start postgresql kafka; \
               runuser -u postgres -- psql -qc \"SELECT pg_cancel_backend(pid) FROM pg_stat_activity WHERE query LIKE '%generate_series(1, 1e12)%' AND pid <> pg_backend_pid()\""
ssh root@$APP "firewall-cmd --remove-rich-rule='rule family=\"ipv4\" source address=\"$WEB\" port port=\"8080\" protocol=\"tcp\" drop' 2>/dev/null; tc qdisc del dev $IFACE root 2>/dev/null; pkill -x yes; pkill -f 'bytearray(3'; systemctl start shop-payment shop-risk shop-backend"
ssh root@$WEB 'systemctl start nginx'

# Tải về mức nền
sed -i 's/^VUS=.*/VUS=2/; s/^BUY_PERCENT=.*/BUY_PERCENT=2/; s/^ORDERS_PER_MIN=.*/ORDERS_PER_MIN=1/' ~/.config/shop-load/env && systemctl --user restart shop-load
check
```
