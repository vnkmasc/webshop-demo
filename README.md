# webshop-demo

Bộ công cụ để **triển khai và chạy demo** ứng dụng [webshop](https://github.com/vnkmasc/webshop) (cửa hàng giày Sải Bước) trên các hạ tầng khác nhau, dùng chung cho mọi hệ thống giám sát.

**Mới dùng lần đầu? Đọc [START-HERE.md](START-HERE.md).**

Repo này **không chứa mã nguồn ứng dụng**. Mã nguồn, cấu hình và cách build nằm ở repo `webshop`; ở đây chỉ có: cách triển khai theo từng loại hạ tầng (target), kịch bản tải, kịch bản sự cố và kiểm thử đầu-cuối.

```
webshop-demo/
├── START-HERE.md         Xem gì, đọc gì, làm gì, test gì - cho người mới
├── targets/
│   └── rhel-3vm/         Ba máy RHEL 9: web (nginx) / ứng dụng (backend + payment container) / CSDL (PostgreSQL)
│       ├── README.md       Hướng dẫn triển khai
│       ├── operations.md   Những gì đang chạy, bật/tắt từng phần, tắt toàn bộ
│       ├── fault-drills.md Bài tập sự cố: lệnh gây sự cố, hiện tượng, khôi phục (DB, mạng, CPU, đĩa, tiến trình...)
│       ├── build-release.sh  Build từ repo webshop + đóng gói kèm script triển khai
│       ├── deploy/         Script cài đặt và triển khai cho từng máy
│       └── nginx/          Cấu hình nginx
├── load/                 Tải giả lập k6 (người xem hàng, người mua, khách quen, quản trị)
├── scenarios/            Kịch bản sự cố và gợi ý buổi demo
└── smoke/                Smoke test đầu-cuối (~60 bước)
```

## Dùng nhanh

```bash
git clone git@github.com:vnkmasc/webshop.git
git clone git@github.com:vnkmasc/webshop-demo.git
cd webshop-demo/targets/rhel-3vm
./build-release.sh 1.0.0 ../../../webshop
# rồi làm theo targets/rhel-3vm/README.md
```

## Thêm target mới

Một target là một thư mục trong `targets/` gồm cách build/đóng gói từ repo `webshop`, script triển khai và tài liệu vận hành (`README.md`, `operations.md`). `load/`, `scenarios/` và `smoke/` dùng chung cho mọi target vì chỉ cần URL của cửa hàng.

Yêu cầu chung của ứng dụng khi demo: `APP_SEED_ENABLED=true` (dữ liệu và tài khoản mẫu) và `APP_SIMULATION_ENABLED=true` (API mô phỏng sự cố). Danh sách biến môi trường đầy đủ: README của repo `webshop`.

## Target hiện có

| Target | Mô tả | Trạng thái |
|---|---|---|
| [`rhel-3vm`](targets/rhel-3vm/README.md) | 3 máy RHEL 9.x; backend Java chạy bằng systemd, cổng thanh toán (Java) và chấm điểm rủi ro (Python) chạy bằng Docker CE, PostgreSQL 16 từ AppStream, nginx kèm kiểm tra readiness | Đang dùng (svfrt / svbe / svdb) |
