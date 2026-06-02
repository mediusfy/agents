-- Migration: GITOPS-02_000_schema_setup.up.sql
-- Prerequisite: Creates the gitops schema if it doesn't exist.
-- Run this before GITOPS-02_001_runbook_definitions.up.sql

CREATE SCHEMA IF NOT EXISTS gitops;
