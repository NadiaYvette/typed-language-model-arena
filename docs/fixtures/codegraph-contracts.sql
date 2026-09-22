-- Tier 1 acceptance gates (CODE_HANDLING §5 / COMBINED_ECOSYSTEM_PLAN §6).
-- Portable SQL against SQLite (repo_graph.sqlite) or Postgres (campaign DB).
-- Each contract is a standalone SELECT: run against the SQLite carrier for
-- CI-speed, and the Postgres carrier for backend-neutrality parity.
-- Naming: contract_N — the testing strategy L4 section refers to these by
-- the same numbers as the plan's Tier 1 acceptance table.

-- Contract 1: formal-logic preds (mowgli) vs concurrency —
--   nodes WHERE repo='mowgli' AND type='pred' AND name IN ('all_in','check')
--   ≥ 2, non-empty line ranges, plus an edge to the defining module.
SELECT n.id, n.name, n.line_start, n.line_end
FROM nodes n
WHERE n.repo = 'mowgli'
  AND n.type = 'pred'
  AND n.name IN ('all_in', 'check')
  AND n.line_start IS NOT NULL
  AND n.line_end IS NOT NULL;

SELECT n.id, n.name, m.path AS module_path
FROM nodes n
JOIN edges e ON e.source_id = n.id
JOIN nodes m ON m.id = e.target_id
WHERE n.repo = 'mowgli'
  AND n.type = 'pred'
  AND n.name IN ('all_in', 'check')
  AND e.relation = 'defines';

-- Contract 2: smirk compileRegex is unique; façade find_symbol returns the
--   same id/line range (façade assertion is in-process; SQL pins uniqueness).
SELECT n.id, n.name, n.line_start, n.line_end
FROM nodes n
WHERE n.repo = 'smirk'
  AND n.name = 'compileRegex';

-- Contract 3: DOI → module edges (academic traceability).
SELECT c.id AS citation_id, c.name AS doi, m.path AS module_path
FROM nodes c
JOIN edges e ON e.source_id = c.id
JOIN nodes m ON m.id = e.target_id
WHERE c.type = 'citation'
  AND m.type = 'module'
  AND e.relation = 'cites';

-- Contract 4: telix ACPI structs — exact names from acpi_srv.rs.
SELECT n.name, n.line_start, n.line_end
FROM nodes n
WHERE n.path LIKE '%acpi_srv.rs'
  AND n.type = 'struct'
  AND n.name IN ('MadtOverride', 'TableEntry', 'AcpiState');

-- Required-language scanner fixtures (strategy §2.5) — run after Tier 1
-- ingestion lands; kept here so the acceptance set is one file.

-- Mercury preds: bounded_loop is the third required mowgli predicate.
SELECT n.name
FROM nodes n
WHERE n.repo = 'mowgli' AND n.type = 'pred' AND n.name = 'bounded_loop';

-- Markdown concepts: headers become type='concept' with line ranges.
SELECT n.name, n.line_start, n.line_end
FROM nodes n
WHERE n.type = 'concept'
  AND n.line_start IS NOT NULL;
