'use strict';

const assert = require('node:assert/strict');
const http = require('node:http');
const { after, before, test } = require('node:test');
const { app, db, validateRuntimeConfig } = require('../server');

let server;
let baseUrl;

before(async () => {
  server = http.createServer(app);
  await new Promise(resolve => server.listen(0, '127.0.0.1', resolve));
  baseUrl = `http://127.0.0.1:${server.address().port}`;
});

after(async () => {
  await new Promise((resolve, reject) => {
    server.close(error => error ? reject(error) : resolve());
  });
  await db.end();
});

test('liveness endpoint returns success without requiring the database', async () => {
  const response = await fetch(`${baseUrl}/health`);

  assert.equal(response.status, 200);
  assert.deepEqual(await response.json(), { status: 'ok' });
});

test('readiness endpoint reports success when the database responds', async () => {
  const originalQuery = db.query;
  db.query = async () => ({ rows: [{ '?column?': 1 }] });

  try {
    const response = await fetch(`${baseUrl}/ready`);

    assert.equal(response.status, 200);
    assert.deepEqual(await response.json(), { status: 'ok', db: 'ok' });
  } finally {
    db.query = originalQuery;
  }
});

test('readiness endpoint reports database unavailability with HTTP 503', async () => {
  const originalQuery = db.query;
  db.query = async () => {
    throw new Error('database unavailable');
  };

  try {
    const response = await fetch(`${baseUrl}/ready`);

    assert.equal(response.status, 503);
    assert.deepEqual(await response.json(), { status: 'not_ready', db: 'down' });
  } finally {
    db.query = originalQuery;
  }
});

test('API health alias reports readiness state', async () => {
  const originalQuery = db.query;
  db.query = async () => {
    throw new Error('database unavailable');
  };

  try {
    const response = await fetch(`${baseUrl}/api/health`);

    assert.equal(response.status, 503);
    assert.deepEqual(await response.json(), { status: 'not_ready', db: 'down' });
  } finally {
    db.query = originalQuery;
  }
});

test('registration rejects malformed fields before accessing the database', async () => {
  const response = await fetch(`${baseUrl}/register`, {
    method: 'POST',
    headers: { 'content-type': 'application/json' },
    body: JSON.stringify({ name: {}, email: 'test@example.com', password: 'password123' }),
  });

  assert.equal(response.status, 400);
});

test('login rejects missing credentials before accessing the database', async () => {
  const response = await fetch(`${baseUrl}/login`, {
    method: 'POST',
    headers: { 'content-type': 'application/json' },
    body: JSON.stringify({ email: 'test@example.com' }),
  });

  assert.equal(response.status, 400);
});

test('registration rejects invalid email and bcrypt-incompatible passwords', async () => {
  const invalidEmail = await fetch(`${baseUrl}/register`, {
    method: 'POST',
    headers: { 'content-type': 'application/json' },
    body: JSON.stringify({ name: 'Test User', email: 'not-an-email', password: 'password123' }),
  });
  const longPassword = await fetch(`${baseUrl}/register`, {
    method: 'POST',
    headers: { 'content-type': 'application/json' },
    body: JSON.stringify({ name: 'Test User', email: 'test@example.com', password: 'a'.repeat(73) }),
  });

  assert.equal(invalidEmail.status, 400);
  assert.equal(longPassword.status, 400);
});

test('JSON request body is limited to 16 KB', async () => {
  const response = await fetch(`${baseUrl}/register`, {
    method: 'POST',
    headers: { 'content-type': 'application/json' },
    body: JSON.stringify({ name: 'x'.repeat(17000), email: 'test@example.com', password: 'password123' }),
  });

  assert.equal(response.status, 413);
  assert.deepEqual(await response.json(), { message: 'Ukuran request maksimal 16 KB.' });
});

test('production configuration requires strong secrets, explicit CORS, and verified database TLS', () => {
  const config = {
    NODE_ENV: 'production',
    JWT_SECRET: 'j'.repeat(32),
    CORS_ORIGIN: 'https://shop.example.com',
    DB_HOST: 'database.example.com',
    DB_NAME: 'arvana_wear',
    DB_USER: 'app',
    DB_PASSWORD: 'database-password',
    DB_SSL: 'verify-full',
    DB_SSL_CA: '/run/secrets/rds-ca.pem',
  };

  assert.doesNotThrow(() => validateRuntimeConfig(config));
  assert.doesNotThrow(() => validateRuntimeConfig({
    ...config,
    CORS_ORIGIN: 'http://arvana-dev.example',
  }));
  assert.throws(
    () => validateRuntimeConfig({ ...config, CORS_ORIGIN: '*' }),
    /CORS_ORIGIN/
  );
  assert.throws(
    () => validateRuntimeConfig({ ...config, DB_SSL: 'false' }),
    /DB_SSL/
  );
  assert.throws(
    () => validateRuntimeConfig({ ...config, JWT_SECRET: 'short' }),
    /JWT_SECRET/
  );
});
