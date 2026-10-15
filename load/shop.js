// k6 load profile for the shop: realistic storefront traffic plus back-office work.
//   ./run.sh http://shop.example.com steady 10 2h
// Personas (share of iterations, overridable with *_PERCENT environment variables):
//   buyer     BUY_PERCENT=25      browse -> cart quote (sometimes a coupon) -> 70% check out (COD or card; some declined)
//   customer  CUSTOMER_PERCENT=10 log in with a load-test account -> order history -> order detail
//   tracker   TRACK_PERCENT=5     guest order lookup
//   admin     ADMIN_PERCENT=5     dashboard -> confirm / ship / deliver orders -> restock sizes that ran out
//   browser   the rest            home -> category / search with filters -> product pages
// On top of that, the "orders" scenario places ORDERS_PER_MIN orders per minute at a fixed rate, whatever the
// mix above does: product -> quote -> order (CARD_PERCENT paid by card, some by a logged-in customer)
// -> order status lookup. This is what keeps checkout, payment, risk and the order queue busy. 0 turns it off.
// Every order this script places has the note "k6", so generated data can be told apart and cleaned up.
import http from 'k6/http';
import { check, group, sleep } from 'k6';
import { Counter, Trend } from 'k6/metrics';

const BASE = (__ENV.BASE_URL || 'http://localhost').replace(/\/$/, '');
const API = `${BASE}/api`;
const PROFILE = __ENV.PROFILE || 'smoke';
const VUS = Number(__ENV.VUS || 10);
const DURATION = __ENV.DURATION || '30m';
const ADMIN_EMAIL = __ENV.ADMIN_EMAIL || 'admin@saibuoc.vn';
const ADMIN_PASSWORD = __ENV.ADMIN_PASSWORD || 'SaiBuoc@2026';
const ORDERS_PER_MIN = Math.max(0, Number(__ENV.ORDERS_PER_MIN ?? 6));
const CARD_SHARE = Math.max(0, Number(__ENV.CARD_PERCENT ?? 50)) / 100;

const ordersPlaced = new Counter('orders_placed');
const ordersFailed = new Counter('orders_payment_failed');
const checkoutDuration = new Trend('checkout_duration', true);

const profiles = {
  smoke: { executor: 'constant-vus', vus: 1, duration: '1m' },
  steady: { executor: 'constant-vus', vus: VUS, duration: DURATION },
  spike: {
    executor: 'ramping-vus', startVUs: 1,
    stages: [{ duration: '2m', target: VUS }, { duration: '1m', target: VUS * 3 }, { duration: '3m', target: VUS * 3 },
      { duration: '2m', target: VUS }, { duration: '2m', target: 0 }],
  },
};

const scenarios = { shop: profiles[PROFILE] || profiles.smoke };
if (ORDERS_PER_MIN > 0) {
  scenarios.orders = {
    executor: 'constant-arrival-rate', exec: 'order', rate: ORDERS_PER_MIN, timeUnit: '1m',
    duration: PROFILE === 'steady' ? DURATION : PROFILE === 'spike' ? '10m' : '1m',
    preAllocatedVUs: Math.max(2, Math.ceil(ORDERS_PER_MIN / 4)), maxVUs: Math.max(10, ORDERS_PER_MIN * 2),
  };
}

export const options = {
  scenarios,
  thresholds: {
    'http_req_failed{kind:read}': ['rate<0.05'],
    'http_req_duration{kind:read}': ['p(95)<1500'],
  },
};

const CATEGORIES = ['giay-chay-bo', 'sneaker', 'giay-tay', 'boot', 'sandal', 'giay-nu', 'giay-da-bong', 'tre-em'];
const SEARCHES = ['chay bo', 'sneaker trang', 'boot', 'sandal', 'velo', 'mekong', 'den', 'giay tay'];
const SORTS = ['newest', 'bestseller', 'price_asc', 'price_desc', 'rating'];
const SIZES = ['36', '38', '39', '40', '41', '42', '43'];
const PROVINCES = ['Hà Nội', 'TP. Hồ Chí Minh', 'Đà Nẵng', 'Hải Phòng', 'Cần Thơ', 'Bình Dương'];
const CARDS = ['4111 1111 1111 1111', '4111 1111 1111 1111', '4111 1111 1111 1111', '5555 5555 5555 4444',
  '4000 0000 0000 0002', '4000 0000 0000 9995'];

const pick = (a) => a[Math.floor(Math.random() * a.length)];
const think = (min = 1, max = 4) => sleep(min + Math.random() * (max - min));
const json = { headers: { 'Content-Type': 'application/json' } };
const read = { tags: { kind: 'read' } };
const auth = (token, kind = 'read') => ({ headers: { 'Content-Type': 'application/json', Authorization: `Bearer ${token}` }, tags: { kind } });

function get(url, params = read) {
  const res = http.get(url, params);
  check(res, { [`GET ${params.tags?.name || url.replace(API, '').split('?')[0]} ok`]: (r) => r.status === 200 });
  return res;
}

function browse() {
  let products = [];
  group('browse', () => {
    get(`${API}/home`, { tags: { kind: 'read', name: '/home' } });
    get(`${API}/site-config`, { tags: { kind: 'read', name: '/site-config' } });
    think();
    const r = Math.random();
    let url;
    if (r < 0.5) url = `${API}/products?category=${pick(CATEGORIES)}&sort=${pick(SORTS)}`;
    else if (r < 0.75) url = `${API}/products?q=${encodeURIComponent(pick(SEARCHES))}`;
    else url = `${API}/products?size=${pick(SIZES)}&sort=${pick(SORTS)}&page=${Math.floor(Math.random() * 3)}`;
    const list = get(url, { tags: { kind: 'read', name: '/products' } });
    products = (list.json('data.content') || []).filter((p) => p.inStock);
    for (let i = 0; i < 1 + Math.floor(Math.random() * 3) && products.length; i++) {
      think();
      get(`${API}/products/${pick(products).slug}`, { tags: { kind: 'read', name: '/products/{slug}' } });
    }
  });
  return products;
}

function buy() {
  const products = browse();
  if (!products.length) return;
  group('checkout', () => {
    const p = pick(products);
    const detail = get(`${API}/products/${p.slug}`, { tags: { kind: 'read', name: '/products/{slug}' } });
    const variants = (detail.json('data.variants') || []).filter((v) => v.stock > 0);
    if (!variants.length) return;
    const items = [{ variantId: pick(variants).id, quantity: Math.random() < 0.85 ? 1 : 2 }];
    const coupon = Math.random() < 0.3 ? pick(['CHAOBAN', 'GIAM200K', 'FREESHIP', 'HE2025']) : undefined;
    const quote = http.post(`${API}/cart/quote`, JSON.stringify({ items, couponCode: coupon }), { ...json, tags: { kind: 'read', name: '/cart/quote' } });
    check(quote, { 'quote ok': (r) => r.status === 200 });
    think(3, 8); // filling in the shipping form
    if (Math.random() < 0.3) return; // abandoned checkout
    placeOrder(items, quote.json('data.couponApplied') ? coupon : undefined, Math.random() < 0.45);
  });
}

// Places one order; returns { code, phone } when it went through.
function placeOrder(items, couponCode, card, token) {
  const n = String(1 + Math.floor(Math.random() * 20)).padStart(2, '0');
  const phone = `09000000${n}`;
  const body = {
    items,
    couponCode,
    customer: { name: `Khách tải ${n}`, phone, address: `${n} Lê Lợi`, province: pick(PROVINCES), note: 'k6' },
    paymentMethod: card ? 'CARD' : 'COD',
    card: card ? { number: pick(CARDS), holder: 'KHACH TAI', expiry: '12/30', cvv: '123' } : undefined,
  };
  const headers = token ? { 'Content-Type': 'application/json', Authorization: `Bearer ${token}` } : json.headers;
  const res = http.post(`${API}/orders`, JSON.stringify(body), { headers, tags: { kind: 'write', name: '/orders' }, timeout: '30s' });
  checkoutDuration.add(res.timings.duration);
  if (res.status === 200) {
    ordersPlaced.add(1);
  } else if (res.status === 422 || res.status === 502) {
    ordersFailed.add(1); // declined card or gateway trouble: a business outcome, not a test failure
  }
  check(res, { 'order placed or payment refused': (r) => [200, 409, 422, 502].includes(r.status) });
  return res.status === 200 ? { code: res.json('data.code'), phone } : null;
}

// Product slugs for the orders scenario, collected once from every category.
export function setup() {
  const slugs = [];
  for (const c of CATEGORIES) {
    const res = http.get(`${API}/products?category=${c}&sort=bestseller`, { tags: { kind: 'read', name: '/products' } });
    for (const p of (res.status === 200 && res.json('data.content')) || []) if (p.inStock) slugs.push(p.slug);
  }
  return { slugs };
}

// "orders" scenario: one straight purchase, then the buyer checks the order like real customers do.
export function order(data) {
  const slugs = data.slugs || [];
  if (!slugs.length) return;
  let token;
  if (Math.random() < 0.3) {
    const n = String(1 + Math.floor(Math.random() * 20)).padStart(2, '0');
    const login = http.post(`${API}/auth/login`, JSON.stringify({ email: `load${n}@saibuoc.vn`, password: __ENV.CUSTOMER_PASSWORD || 'SaiBuoc@2026' }), { ...json, tags: { kind: 'read', name: '/auth/login' } });
    if (login.status === 200) token = login.json('data.accessToken');
  }
  group('order', () => {
    const detail = get(`${API}/products/${pick(slugs)}`, { tags: { kind: 'read', name: '/products/{slug}' } });
    const variants = (detail.json('data.variants') || []).filter((v) => v.stock > 0);
    if (!variants.length) return;
    const items = [{ variantId: pick(variants).id, quantity: Math.random() < 0.85 ? 1 : 2 }];
    const coupon = Math.random() < 0.3 ? pick(['CHAOBAN', 'GIAM200K', 'FREESHIP', 'HE2025']) : undefined;
    const quote = http.post(`${API}/cart/quote`, JSON.stringify({ items, couponCode: coupon }), { ...json, tags: { kind: 'read', name: '/cart/quote' } });
    check(quote, { 'quote ok': (r) => r.status === 200 });
    think(1, 3);
    const placed = placeOrder(items, quote.json('data.couponApplied') ? coupon : undefined, Math.random() < CARD_SHARE, token);
    if (!placed) return;
    think(1, 3);
    if (token) {
      get(`${API}/account/orders/${placed.code}`, { ...auth(token), tags: { kind: 'read', name: '/account/orders/{code}' } });
    } else {
      get(`${API}/orders/lookup?code=${placed.code}&phone=${placed.phone}`, { tags: { kind: 'lookup', name: '/orders/lookup' } });
    }
  });
}

function customer() {
  const n = String(1 + Math.floor(Math.random() * 20)).padStart(2, '0');
  const login = http.post(`${API}/auth/login`, JSON.stringify({ email: `load${n}@saibuoc.vn`, password: __ENV.CUSTOMER_PASSWORD || 'SaiBuoc@2026' }), { ...json, tags: { kind: 'read', name: '/auth/login' } });
  if (!check(login, { 'customer login': (r) => r.status === 200 })) return;
  const token = login.json('data.accessToken');
  think();
  const orders = get(`${API}/account/orders`, { ...auth(token), tags: { kind: 'read', name: '/account/orders' } });
  const list = orders.json('data') || [];
  if (list.length) {
    think();
    get(`${API}/account/orders/${pick(list).code}`, { ...auth(token), tags: { kind: 'read', name: '/account/orders/{code}' } });
  }
}

function tracker() {
  const n = String(1 + Math.floor(Math.random() * 20)).padStart(2, '0');
  // Unknown codes are expected to 404: it exercises the lookup path like mistyped real lookups.
  const res = http.get(`${API}/orders/lookup?code=SB${100000 + Math.floor(Math.random() * 3000)}&phone=09000000${n}`,
    { tags: { kind: 'lookup', name: '/orders/lookup' } });
  check(res, { 'lookup answered': (r) => r.status === 200 || r.status === 404 });
}

function admin() {
  const login = http.post(`${API}/auth/login`, JSON.stringify({ email: ADMIN_EMAIL, password: ADMIN_PASSWORD }), { ...json, tags: { kind: 'read', name: '/auth/login' } });
  if (!check(login, { 'admin login': (r) => r.status === 200 })) return;
  const t = login.json('data.accessToken');
  group('admin', () => {
    get(`${API}/admin/dashboard?days=${pick([1, 7, 30])}`, { ...auth(t), tags: { kind: 'read', name: '/admin/dashboard' } });
    think();
    // Move orders forward through the life cycle, oldest first.
    for (const [from, to] of [['PENDING', 'CONFIRMED'], ['CONFIRMED', 'SHIPPING'], ['SHIPPING', 'DELIVERED']]) {
      const page = get(`${API}/admin/orders?status=${from}&size=5`, { ...auth(t), tags: { kind: 'read', name: '/admin/orders' } });
      const rows = (page.json('data.content') || []).filter((o) => from !== 'PENDING' || o.paymentMethod === 'COD' || o.paymentStatus === 'PAID');
      for (const o of rows.slice(-2)) {
        http.post(`${API}/admin/orders/${o.code}/status`, JSON.stringify({ status: to }), { ...auth(t, 'write'), tags: { kind: 'write', name: '/admin/orders/{code}/status' } });
      }
      think(0.5, 1.5);
    }
    // Restock: sizes that ran out get new stock (keeps long-running tests from emptying the shop).
    const low = get(`${API}/admin/products?lowStock=true&size=3`, { ...auth(t), tags: { kind: 'read', name: '/admin/products' } });
    for (const row of low.json('data.content') || []) {
      const p = http.get(`${API}/admin/products/${row.id}`, auth(t)).json('data');
      if (!p) continue;
      const lines = p.variants.filter((v) => v.stock <= 3).map((v) => ({ size: v.size, stock: 15 + Math.floor(Math.random() * 15) }));
      if (lines.length) http.put(`${API}/admin/products/${row.id}/stock`, JSON.stringify({ lines }), { ...auth(t, 'write'), tags: { kind: 'write', name: '/admin/products/{id}/stock' } });
    }
  });
}

const pct = (name, def) => Math.max(0, Number(__ENV[name] ?? def)) / 100;
const BUY = pct('BUY_PERCENT', 25);
const CUSTOMER = pct('CUSTOMER_PERCENT', 10);
const TRACK = pct('TRACK_PERCENT', 5);
const ADMIN = pct('ADMIN_PERCENT', 5);

export default function () {
  const r = Math.random();
  if (r < BUY) buy();
  else if (r < BUY + CUSTOMER) customer();
  else if (r < BUY + CUSTOMER + TRACK) tracker();
  else if (r < BUY + CUSTOMER + TRACK + ADMIN) admin();
  else browse();
  think(2, 6);
}
