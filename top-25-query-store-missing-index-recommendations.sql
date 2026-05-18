-- =============================================================================
-- Top 25 Missing Index Recommendations (SQL Server 2017 Compatible)
-- =============================================================================
-- Description:  Identifies the top 25 missing indexes using SQL Server's
--               missing index DMVs.
--
--               NOTE: SQL Server 2017 does NOT expose
--               sys.dm_db_missing_index_group_stats_query (introduced in
--               SQL Server 2019). That DMV is what enables joining a missing
--               index group to specific Query Store queries via query_hash.
--               As a result, this 2017 port drops:
--                  - Query Store cross-reference
--                  - Business-hours filtering (weekdays 07:30-18:30)
--                  - Per-query memory and logical IO metrics
--                  - query_id_highest_impact lookup
--                  - qs_calculated_impact (impact x real execution time)
--
--               It retains:
--                  - DMV-based impact scoring (Pinal Dave's classic formula)
--                  - Write activity on the clustered index
--                  - Existing index count per table
--                  - Ready-to-run CREATE INDEX statement
--
-- Original Author: Pinal Dave (SQLAuthority.com)
-- Extended by:     Joao Barbosa
-- 2017 Port:       Removes 2019+ DMV dependencies
--
-- Requirements:    SQL Server 2017 (or later)
-- Usage:           Execute in the context of the target database
--                  USE [YourDatabaseName];
-- =============================================================================

SELECT TOP 25
    -- Table identification
    DB_NAME(mid.database_id)                                          AS database_name,
    sche.name                                                         AS schema_name,
    tab.name                                                          AS table_name,
    migs.group_handle,

    -- DMV-based impact (traditional Pinal Dave calculation)
    CAST(migs.avg_total_user_cost
         * migs.avg_user_impact
         * (migs.user_seeks + migs.user_scans) AS BIGINT)             AS dmv_calculated_impact,

    migs.avg_user_impact                                              AS percent_impact,
    migs.last_user_seek,
    migs.last_user_scan,
    migs.user_seeks,
    migs.user_scans,
    migs.avg_total_user_cost,
    migs.avg_total_system_cost,
    migs.unique_compiles,

    -- Write activity on the clustered index (index maintenance cost indicator)
    (
        SELECT TOP 1 u.user_updates
        FROM sys.dm_db_index_usage_stats AS u
        INNER JOIN sys.indexes AS i
            ON u.object_id = i.object_id AND u.index_id = i.index_id
        WHERE u.object_id = tab.object_id
            AND i.index_id = 1
            AND u.database_id = DB_ID()
    )                                                                 AS writes_on_pk,

    -- Total indexes on this table (avoid over-indexing)
    (
        SELECT COUNT(*)
        FROM sys.indexes AS i
        WHERE i.object_id = tab.object_id
            AND i.index_id > 0
    )                                                                 AS existing_index_count,

    -- Missing index details
    mid.equality_columns,
    mid.inequality_columns,
    mid.included_columns,

    -- Ready-to-use CREATE INDEX statement
    'CREATE INDEX [IX_' + OBJECT_NAME(mid.object_id, mid.database_id) + '_'
        + REPLACE(REPLACE(REPLACE(ISNULL(mid.equality_columns, ''), ', ', '_'), '[', ''), ']', '')
        + CASE
            WHEN mid.equality_columns IS NOT NULL AND mid.inequality_columns IS NOT NULL THEN '_'
            ELSE ''
          END
        + REPLACE(REPLACE(REPLACE(ISNULL(mid.inequality_columns, ''), ', ', '_'), '[', ''), ']', '')
        + '] ON ' + mid.statement
        + ' (' + ISNULL(mid.equality_columns, '')
        + CASE
            WHEN mid.equality_columns IS NOT NULL AND mid.inequality_columns IS NOT NULL THEN ', '
            ELSE ''
          END
        + ISNULL(mid.inequality_columns, '')
        + ')'
        + ISNULL(' INCLUDE (' + mid.included_columns + ')', '')       AS create_statement

FROM sys.dm_db_missing_index_groups AS mig
INNER JOIN sys.dm_db_missing_index_group_stats AS migs
    ON migs.group_handle = mig.index_group_handle
INNER JOIN sys.dm_db_missing_index_details AS mid
    ON mig.index_handle = mid.index_handle
INNER JOIN sys.objects AS tab
    ON mid.object_id = tab.object_id
INNER JOIN sys.schemas AS sche
    ON tab.schema_id = sche.schema_id
WHERE
    mid.database_id = DB_ID()
ORDER BY
    dmv_calculated_impact DESC
OPTION (MAXDOP 1);
GO
