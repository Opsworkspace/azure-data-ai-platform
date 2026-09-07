-- ---------------------------------------------------------------------------
-- Grants.
--
-- Every grant here is to a GROUP, never to a user. A person who joins the team
-- gets access by joining the group; a person who leaves loses it by leaving.
-- Granting to individuals produces a permission model that has to be edited
-- every time someone changes role, which means it is never accurate.
--
-- The privilege model is hierarchical: a privilege on a catalog is inherited
-- by its schemas and their tables. That makes it easy to over-grant, so the
-- rule applied here is to grant at the NARROWEST level that serves the
-- audience.
--
-- Note that USE CATALOG and USE SCHEMA are traversal rights, not read rights.
-- A principal needs USE on the catalog AND USE on the schema AND SELECT on the
-- table to read it. Granting SELECT without USE produces a permission error
-- that names the table, which sends people looking in the wrong place.
-- ---------------------------------------------------------------------------

USE CATALOG purple_prod;

-- --- platform engineers ----------------------------------------------------
-- Full control, because they are accountable for the platform. Note this is
-- still not the metastore admin role: creating catalogs and managing storage
-- credentials stays with a smaller group.
GRANT ALL PRIVILEGES ON CATALOG purple_prod TO `purple-platform-engineers`;

-- --- data engineers --------------------------------------------------------
-- Read everything, write to silver and gold. NOT to bronze.
--
-- Bronze is written only by ingest jobs. If an engineer can write to bronze,
-- then bronze is no longer "exactly what the source sent" — and the guarantee
-- that lets you re-derive everything downstream is gone. This restriction is
-- the enforcement of the medallion architecture's central promise.
GRANT USE CATALOG ON CATALOG purple_prod TO `purple-data-engineers`;
GRANT USE SCHEMA ON SCHEMA bronze TO `purple-data-engineers`;
GRANT SELECT ON SCHEMA bronze TO `purple-data-engineers`;

GRANT USE SCHEMA, CREATE TABLE, MODIFY, SELECT ON SCHEMA silver TO `purple-data-engineers`;
GRANT USE SCHEMA, CREATE TABLE, MODIFY, SELECT ON SCHEMA gold TO `purple-data-engineers`;

-- --- analysts --------------------------------------------------------------
-- Gold only, read only. Analysts should not be reading silver: silver is
-- reproducible intermediate state whose shape changes as pipelines evolve, and
-- a dashboard built on it breaks without warning. Gold is the contract.
GRANT USE CATALOG ON CATALOG purple_prod TO `purple-analysts`;
GRANT USE SCHEMA ON SCHEMA gold TO `purple-analysts`;
GRANT SELECT ON SCHEMA gold TO `purple-analysts`;

-- --- the ingest service principal -----------------------------------------
-- Writes bronze, reads nothing else. Least privilege for a machine identity:
-- it does exactly one job.
GRANT USE CATALOG ON CATALOG purple_prod TO `purple-ingest-sp`;
GRANT USE SCHEMA, CREATE TABLE, MODIFY ON SCHEMA bronze TO `purple-ingest-sp`;

-- ---------------------------------------------------------------------------
-- Row-level security and column masking.
--
-- Unity Catalog enforces these at query time, for EVERY access path — SQL
-- warehouse, notebook, JDBC, Power BI. That is what makes them trustworthy: a
-- filter applied in a dashboard tool protects only that dashboard.
-- ---------------------------------------------------------------------------

-- Column mask: analysts see a hashed email, platform engineers see the real
-- one. The same query returns different values depending on who runs it.
CREATE OR REPLACE FUNCTION gold.mask_email(email STRING)
  RETURNS STRING
  RETURN CASE
    WHEN is_account_group_member('purple-platform-engineers') THEN email
    ELSE sha2(email, 256)
  END;

-- Row filter: restricts rows to the caller's own tenant, unless they are
-- platform staff. This is the SQL-side equivalent of the RAG filter in
-- services/api/purple_api/rag.py — the same principle applied to a different
-- access path, because a tenant boundary enforced in only one of them is not
-- a tenant boundary.
CREATE OR REPLACE FUNCTION gold.tenant_filter(tenant_id STRING)
  RETURNS BOOLEAN
  RETURN is_account_group_member('purple-platform-engineers')
      OR tenant_id = current_user();

-- Applied to a table with:
--   ALTER TABLE gold.user_activity SET ROW FILTER gold.tenant_filter ON (tenant_id);
--   ALTER TABLE gold.user_activity ALTER COLUMN email SET MASK gold.mask_email;
