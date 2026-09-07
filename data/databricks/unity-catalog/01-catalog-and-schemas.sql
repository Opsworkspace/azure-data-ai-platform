-- ---------------------------------------------------------------------------
-- Unity Catalog: the governance objects.
--
-- Run once per environment, by a metastore admin. These statements are
-- idempotent, so re-running is safe.
--
-- The three-level namespace is catalog.schema.table. Choosing what each level
-- means is a governance decision, not a naming one:
--
--   CATALOG = the ENVIRONMENT boundary.
--     purple_dev, purple_stage, purple_prod. This is the level at which access is
--     granted wholesale, so "data scientists can read prod gold but nothing
--     else" is one grant. Using catalogs for business domains instead is a
--     common choice that makes environment isolation impossible to express.
--
--   SCHEMA = the MEDALLION LAYER.
--     bronze, silver, gold. Different audiences: engineers read bronze,
--     analysts read gold. A grant per schema matches how people actually work.
--
--   TABLE = the grant boundary for anything finer.
-- ---------------------------------------------------------------------------

-- --- storage credential ----------------------------------------------------
-- The bridge to Azure. It wraps the Databricks Access Connector's managed
-- identity, created in infra/terraform/modules/databricks.
--
-- This is the ONLY thing in the data platform that holds storage access.
-- No user, no cluster, and no notebook has a storage key: they are granted
-- tables, and Unity Catalog brokers the storage read on their behalf.
CREATE STORAGE CREDENTIAL IF NOT EXISTS purple_lakehouse_credential
  WITH AZURE_MANAGED_IDENTITY (
    ACCESS_CONNECTOR_ID = '/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/purple-data-prod-eus2-rg/providers/Microsoft.Databricks/accessConnectors/purple-data-prod-eus2-dbw-uc-connector'
  )
  COMMENT 'Managed identity of the Databricks access connector. The only principal with direct data-plane access to the lakehouse storage account.';

-- --- external locations ----------------------------------------------------
-- An external location binds a storage path to a credential. Granting someone
-- CREATE EXTERNAL TABLE on a location lets them create tables over that path
-- and nothing else — which is how a team is given one container rather than
-- the storage account.
--
-- Note the abfss:// scheme. It resolves through the dfs private endpoint, so
-- BOTH the blob and dfs private DNS zones must be linked to the Databricks
-- VNet. Linking only blob produces a workspace where these statements fail
-- with a network timeout that mentions neither DNS nor the endpoint.
CREATE EXTERNAL LOCATION IF NOT EXISTS purple_bronze
  URL 'abfss://bronze@purpledataprodeus2000000.dfs.core.windows.net/'
  WITH (STORAGE CREDENTIAL purple_lakehouse_credential)
  COMMENT 'Raw ingested data. Append only.';

CREATE EXTERNAL LOCATION IF NOT EXISTS purple_silver
  URL 'abfss://silver@purpledataprodeus2000000.dfs.core.windows.net/'
  WITH (STORAGE CREDENTIAL purple_lakehouse_credential)
  COMMENT 'Cleaned, conformed, deduplicated data.';

CREATE EXTERNAL LOCATION IF NOT EXISTS purple_gold
  URL 'abfss://gold@purpledataprodeus2000000.dfs.core.windows.net/'
  WITH (STORAGE CREDENTIAL purple_lakehouse_credential)
  COMMENT 'Business-level aggregates consumed by the API and dashboards.';

-- --- catalog ---------------------------------------------------------------
CREATE CATALOG IF NOT EXISTS purple_prod
  COMMENT 'Production data for the Purple platform. Environment boundary.';

USE CATALOG purple_prod;

CREATE SCHEMA IF NOT EXISTS bronze
  MANAGED LOCATION 'abfss://bronze@purpledataprodeus2000000.dfs.core.windows.net/managed'
  COMMENT 'Raw, immutable, exactly as received. Never edited, only appended.';

CREATE SCHEMA IF NOT EXISTS silver
  MANAGED LOCATION 'abfss://silver@purpledataprodeus2000000.dfs.core.windows.net/managed'
  COMMENT 'Cleaned, conformed, deduplicated, schema-enforced.';

CREATE SCHEMA IF NOT EXISTS gold
  MANAGED LOCATION 'abfss://gold@purpledataprodeus2000000.dfs.core.windows.net/managed'
  COMMENT 'Aggregated and business-shaped. What the API and dashboards read.';
