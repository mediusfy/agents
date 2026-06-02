-- Migration: GITOPS-02_000_schema_setup.down.sql
-- Drops the gitops schema if it exists and is empty.

-- NOTE: This is a no-op if other objects exist in the gitops schema.
-- DROP SCHEMA IF EXISTS gitops CASCADE;
