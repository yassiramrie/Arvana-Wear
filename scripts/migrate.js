'use strict';

const fs = require('node:fs');
const path = require('node:path');
const { Pool } = require('pg');

const caPath = process.env.DB_SSL_CA;
if (process.env.DB_SSL !== 'verify-full' || !caPath) {
  throw new Error('DB_SSL=verify-full and DB_SSL_CA are required for migrations.');
}

const dbConfig = {
  host: process.env.DB_HOST,
  port: Number(process.env.DB_PORT || 5432),
  database: process.env.DB_NAME,
  ssl: {
    rejectUnauthorized: true,
    ca: fs.readFileSync(caPath, 'utf8'),
  },
  connectionTimeoutMillis: 10000,
};
const adminPool = new Pool({
  ...dbConfig,
  user: process.env.DB_ADMIN_USER,
  password: process.env.DB_ADMIN_PASSWORD,
});

async function migrate() {
  if (!process.env.DB_ADMIN_USER || !process.env.DB_ADMIN_PASSWORD || !process.env.DB_USER || !process.env.DB_PASSWORD) {
    throw new Error('Database migration and application credentials are required.');
  }

  const roleExists = await adminPool.query(
    'SELECT EXISTS (SELECT 1 FROM pg_roles WHERE rolname = $1) AS exists',
    [process.env.DB_USER]
  );
  const roleStatement = roleExists.rows[0].exists
    ? 'ALTER ROLE %I WITH LOGIN PASSWORD %L'
    : 'CREATE ROLE %I WITH LOGIN PASSWORD %L';
  const roleSql = await adminPool.query(
    `SELECT format('${roleStatement}', $1::text, $2::text) AS statement`,
    [process.env.DB_USER, process.env.DB_PASSWORD]
  );
  await adminPool.query(roleSql.rows[0].statement);

  const databaseAccess = await adminPool.query(
    'SELECT format(\'GRANT CONNECT ON DATABASE %I TO %I\', $1::text, $2::text) AS statement',
    [process.env.DB_NAME, process.env.DB_USER]
  );
  await adminPool.query(databaseAccess.rows[0].statement);

  const sql = fs.readFileSync(path.join(__dirname, '..', 'init.sql'), 'utf8');
  await adminPool.query(sql);

  const privileges = await adminPool.query(
    `SELECT format(
      'GRANT SELECT, INSERT, UPDATE, DELETE ON ALL TABLES IN SCHEMA public TO %I; GRANT USAGE, SELECT ON ALL SEQUENCES IN SCHEMA public TO %I; ALTER DEFAULT PRIVILEGES IN SCHEMA public GRANT SELECT, INSERT, UPDATE, DELETE ON TABLES TO %I; ALTER DEFAULT PRIVILEGES IN SCHEMA public GRANT USAGE, SELECT ON SEQUENCES TO %I',
      $1::text, $1::text, $1::text, $1::text
    ) AS statement`,
    [process.env.DB_USER]
  );
  await adminPool.query(privileges.rows[0].statement);

  console.log('Database schema is up to date.');
}

migrate()
  .catch(error => {
    console.error(JSON.stringify({
      level: 'error',
      event: 'database_migration_failed',
      message: error.message,
    }));
    process.exitCode = 1;
  })
  .finally(() => adminPool.end());
