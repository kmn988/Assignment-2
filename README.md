# EB Games data platform - how to run

Requires Docker Desktop.

1. Create your environment file and set a password:
   ```bash
   cp .env.example .env
   ```
2. Start the databases and Metabase:
   ```bash
   docker compose up -d postgres metabase
   ```
   On the first start, every `.sql` file in `db/init/` runs once, in alphabetical order.
3. Check the setup ran without errors:
   ```bash
   docker compose logs postgres
   ```
4. Open Metabase at http://localhost:3000. On the first visit it asks you to create an admin account
   (any name, email and password; it is stored only in your local `metabase_db`, not online).
   Then add the warehouse: PostgreSQL, host `postgres`, port `5432`, database `warehouse_db`, and the
   user and password from `.env`.

Connect from your own tools (DBeaver, `psql`): host `localhost`, port `5432`, user and password from `.env`.

Stop: `docker compose down`

Reset everything and re-run `db/init` (deletes all data):
```bash
docker compose down -v
docker compose up -d postgres metabase
```
