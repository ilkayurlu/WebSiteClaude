-- Stage 2 service runtime foundation.
-- Adds trusted service clients, scheduler/job state, retention policy hooks,
-- and service-side H3/runtime metadata that complements Stage 1 tables.

CREATE EXTENSION IF NOT EXISTS pgcrypto;

CREATE TABLE IF NOT EXISTS app.service_api_clients (
    id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    tenant_id uuid NOT NULL REFERENCES app.tenants(id),
    name text NOT NULL,
    client_kind text NOT NULL
        CHECK (client_kind IN ('gateway', 'edge', 'scheduler', 'iot', 'internal')),
    signing_method text NOT NULL
        CHECK (signing_method IN ('hmac_sha256', 'jwt')),
    public_key text,
    client_secret_hash bytea NOT NULL,
    scopes text[] NOT NULL DEFAULT ARRAY[]::text[],
    status text NOT NULL DEFAULT 'enabled'
        CHECK (status IN ('enabled', 'disabled', 'revoked')),
    created_by uuid REFERENCES app.users(id),
    created_at timestamptz NOT NULL DEFAULT now(),
    updated_at timestamptz NOT NULL DEFAULT now(),
    last_seen_at timestamptz,
    UNIQUE (tenant_id, name),
    UNIQUE (id, tenant_id)
);

CREATE INDEX service_api_clients_tenant_status_idx
    ON app.service_api_clients (tenant_id, status, client_kind);

CREATE TABLE IF NOT EXISTS app.service_api_tokens (
    id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    tenant_id uuid NOT NULL REFERENCES app.tenants(id),
    client_id uuid NOT NULL,
    subject text NOT NULL,
    token_hash bytea NOT NULL,
    scopes text[] NOT NULL DEFAULT ARRAY[]::text[],
    issued_at timestamptz NOT NULL DEFAULT now(),
    expires_at timestamptz NOT NULL,
    revoked_at timestamptz,
    metadata jsonb NOT NULL DEFAULT '{}'::jsonb
        CHECK (jsonb_typeof(metadata) = 'object'),
    CHECK (expires_at > issued_at),
    UNIQUE (tenant_id, token_hash),
    FOREIGN KEY (client_id, tenant_id)
        REFERENCES app.service_api_clients (id, tenant_id)
);

CREATE INDEX service_api_tokens_client_expiry_idx
    ON app.service_api_tokens (tenant_id, client_id, expires_at DESC);

CREATE TABLE IF NOT EXISTS app.retention_policies (
    id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    tenant_id uuid NOT NULL REFERENCES app.tenants(id),
    resource_table text NOT NULL,
    retention_days integer NOT NULL CHECK (retention_days > 0),
    active boolean NOT NULL DEFAULT true,
    created_by uuid REFERENCES app.users(id),
    created_at timestamptz NOT NULL DEFAULT now(),
    updated_at timestamptz NOT NULL DEFAULT now(),
    UNIQUE (tenant_id, resource_table)
);

CREATE TABLE IF NOT EXISTS app.service_jobs (
    id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    tenant_id uuid NOT NULL REFERENCES app.tenants(id),
    job_type text NOT NULL
        CHECK (job_type IN (
            'retention', 'h3_rebuild', 'telemetry_backfill',
            'payout_batch', 'zone_validation', 'sync_iot_inventory'
        )),
    status text NOT NULL DEFAULT 'queued'
        CHECK (status IN ('queued', 'running', 'succeeded', 'failed', 'cancelled')),
    priority integer NOT NULL DEFAULT 100 CHECK (priority BETWEEN 0 AND 1000),
    scheduled_for timestamptz NOT NULL DEFAULT now(),
    started_at timestamptz,
    finished_at timestamptz,
    attempts integer NOT NULL DEFAULT 0 CHECK (attempts >= 0),
    payload jsonb NOT NULL DEFAULT '{}'::jsonb
        CHECK (jsonb_typeof(payload) = 'object'),
    result jsonb,
    created_by uuid REFERENCES app.users(id),
    created_at timestamptz NOT NULL DEFAULT now(),
    updated_at timestamptz NOT NULL DEFAULT now(),
    CHECK (finished_at IS NULL OR finished_at >= started_at)
);

CREATE INDEX service_jobs_tenant_status_idx
    ON app.service_jobs (tenant_id, status, scheduled_for);
CREATE INDEX service_jobs_type_priority_idx
    ON app.service_jobs (job_type, priority DESC, scheduled_for);

CREATE TABLE IF NOT EXISTS app.h3_library_versions (
    id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    tenant_id uuid NOT NULL REFERENCES app.tenants(id),
    library_name text NOT NULL DEFAULT 'h3',
    library_version text NOT NULL,
    resolution smallint NOT NULL CHECK (resolution BETWEEN 0 AND 15),
    enabled boolean NOT NULL DEFAULT true,
    metadata jsonb NOT NULL DEFAULT '{}'::jsonb
        CHECK (jsonb_typeof(metadata) = 'object'),
    created_at timestamptz NOT NULL DEFAULT now(),
    UNIQUE (tenant_id, library_name, library_version, resolution)
);

CREATE TABLE IF NOT EXISTS app.iot_device_sessions (
    id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    tenant_id uuid NOT NULL REFERENCES app.tenants(id),
    vehicle_id uuid NOT NULL,
    device_id uuid NOT NULL,
    session_key_hash bytea NOT NULL,
    status text NOT NULL DEFAULT 'active'
        CHECK (status IN ('active', 'expired', 'revoked', 'fault')),
    started_at timestamptz NOT NULL DEFAULT now(),
    expires_at timestamptz NOT NULL,
    last_seen_at timestamptz,
    metadata jsonb NOT NULL DEFAULT '{}'::jsonb
        CHECK (jsonb_typeof(metadata) = 'object'),
    created_at timestamptz NOT NULL DEFAULT now(),
    FOREIGN KEY (vehicle_id, tenant_id)
        REFERENCES app.iot_vehicles (id, tenant_id),
    FOREIGN KEY (device_id, tenant_id)
        REFERENCES app.vehicle_devices (id, tenant_id),
    CHECK (expires_at > started_at)
);

CREATE INDEX iot_device_sessions_vehicle_active_idx
    ON app.iot_device_sessions (tenant_id, vehicle_id, status, expires_at DESC);

CREATE TABLE IF NOT EXISTS app.service_event_logs (
    id bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    tenant_id uuid NOT NULL REFERENCES app.tenants(id),
    source_type text NOT NULL
        CHECK (source_type IN ('service_api', 'scheduler', 'iot_device', 'retention')),
    source_id uuid,
    event_type text NOT NULL,
    event_data jsonb NOT NULL DEFAULT '{}'::jsonb
        CHECK (jsonb_typeof(event_data) = 'object'),
    actor_user_id uuid REFERENCES app.users(id),
    occurred_at timestamptz NOT NULL DEFAULT now()
);

CREATE INDEX service_event_logs_tenant_time_idx
    ON app.service_event_logs (tenant_id, occurred_at DESC);

CREATE FUNCTION app.current_service_client_id()
RETURNS uuid
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path = pg_catalog, app
AS $$
    SELECT CASE
        WHEN NULLIF(current_setting('request.jwt.claims', true), '') IS NOT NULL
             AND NULLIF(current_setting('request.jwt.claims', true), '')::jsonb ->> 'service_client_id'
                 ~ '^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$'
            THEN (NULLIF(current_setting('request.jwt.claims', true), '')::jsonb ->> 'service_client_id')::uuid
        WHEN NULLIF(current_setting('request.jwt.claim.sub', true), '') IS NOT NULL
             AND NULLIF(current_setting('request.jwt.claim.sub', true), '')
                 ~ '^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$'
            THEN NULLIF(current_setting('request.jwt.claim.sub', true), '')::uuid
        ELSE NULL
    END
$$;

CREATE FUNCTION app.can_manage_service_runtime(target_tenant uuid)
RETURNS boolean
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path = pg_catalog, app
AS $$
    SELECT app.has_tenant_role(
               target_tenant,
               ARRAY['tenant_owner', 'admin', 'ops']::text[]
           )
        OR EXISTS (
            SELECT 1
            FROM service_api_clients AS c
            WHERE c.id = app.current_service_client_id()
              AND c.tenant_id = target_tenant
              AND c.status = 'enabled'
        )
$$;

CREATE FUNCTION app.touch_updated_at()
RETURNS trigger
LANGUAGE plpgsql
SET search_path = pg_catalog, app
AS $$
BEGIN
    NEW.updated_at := now();
    RETURN NEW;
END;
$$;

CREATE TRIGGER service_api_clients_touch_updated_at
BEFORE UPDATE ON app.service_api_clients
FOR EACH ROW EXECUTE FUNCTION app.touch_updated_at();

CREATE TRIGGER retention_policies_touch_updated_at
BEFORE UPDATE ON app.retention_policies
FOR EACH ROW EXECUTE FUNCTION app.touch_updated_at();

CREATE TRIGGER service_jobs_touch_updated_at
BEFORE UPDATE ON app.service_jobs
FOR EACH ROW EXECUTE FUNCTION app.touch_updated_at();

ALTER TABLE app.service_api_clients ENABLE ROW LEVEL SECURITY;
CREATE POLICY service_api_clients_tenant_read ON app.service_api_clients
    FOR SELECT USING (app.can_manage_service_runtime(tenant_id));
CREATE POLICY service_api_clients_tenant_write ON app.service_api_clients
    FOR INSERT WITH CHECK (app.can_manage_service_runtime(tenant_id));
CREATE POLICY service_api_clients_tenant_update ON app.service_api_clients
    FOR UPDATE
    USING (app.can_manage_service_runtime(tenant_id))
    WITH CHECK (app.can_manage_service_runtime(tenant_id));

ALTER TABLE app.service_api_tokens ENABLE ROW LEVEL SECURITY;
CREATE POLICY service_api_tokens_tenant_read ON app.service_api_tokens
    FOR SELECT USING (
        app.can_manage_service_runtime(tenant_id)
        OR client_id IN (
            SELECT id FROM app.service_api_clients
            WHERE tenant_id = app.service_api_tokens.tenant_id
              AND app.current_service_client_id() = id
        )
    );
CREATE POLICY service_api_tokens_tenant_write ON app.service_api_tokens
    FOR INSERT WITH CHECK (app.can_manage_service_runtime(tenant_id));

ALTER TABLE app.retention_policies ENABLE ROW LEVEL SECURITY;
CREATE POLICY retention_policies_ops_read ON app.retention_policies
    FOR SELECT USING (
        app.has_tenant_role(tenant_id, ARRAY['tenant_owner', 'admin', 'ops', 'security']::text[])
    );
CREATE POLICY retention_policies_ops_write ON app.retention_policies
    FOR INSERT WITH CHECK (
        app.has_tenant_role(tenant_id, ARRAY['tenant_owner', 'admin', 'ops']::text[])
    );
CREATE POLICY retention_policies_ops_update ON app.retention_policies
    FOR UPDATE
    USING (app.has_tenant_role(tenant_id, ARRAY['tenant_owner', 'admin', 'ops']::text[]))
    WITH CHECK (app.has_tenant_role(tenant_id, ARRAY['tenant_owner', 'admin', 'ops']::text[]));

ALTER TABLE app.service_jobs ENABLE ROW LEVEL SECURITY;
CREATE POLICY service_jobs_tenant_read ON app.service_jobs
    FOR SELECT USING (app.can_manage_service_runtime(tenant_id));
CREATE POLICY service_jobs_tenant_write ON app.service_jobs
    FOR INSERT WITH CHECK (app.can_manage_service_runtime(tenant_id));
CREATE POLICY service_jobs_tenant_update ON app.service_jobs
    FOR UPDATE
    USING (app.can_manage_service_runtime(tenant_id))
    WITH CHECK (app.can_manage_service_runtime(tenant_id));

ALTER TABLE app.h3_library_versions ENABLE ROW LEVEL SECURITY;
CREATE POLICY h3_library_versions_member_read ON app.h3_library_versions
    FOR SELECT USING (app.has_tenant_access(tenant_id));
CREATE POLICY h3_library_versions_ops_write ON app.h3_library_versions
    FOR INSERT WITH CHECK (
        app.has_tenant_role(tenant_id, ARRAY['tenant_owner', 'admin', 'ops']::text[])
    );
CREATE POLICY h3_library_versions_ops_update ON app.h3_library_versions
    FOR UPDATE
    USING (app.has_tenant_role(tenant_id, ARRAY['tenant_owner', 'admin', 'ops']::text[]))
    WITH CHECK (app.has_tenant_role(tenant_id, ARRAY['tenant_owner', 'admin', 'ops']::text[]));

ALTER TABLE app.iot_device_sessions ENABLE ROW LEVEL SECURITY;
CREATE POLICY iot_device_sessions_ops_read ON app.iot_device_sessions
    FOR SELECT USING (
        app.has_tenant_role(
            tenant_id,
            ARRAY['tenant_owner', 'admin', 'ops', 'dispatcher', 'field_operator', 'security']::text[]
        )
    );
CREATE POLICY iot_device_sessions_ops_write ON app.iot_device_sessions
    FOR INSERT WITH CHECK (
        app.has_tenant_role(tenant_id, ARRAY['tenant_owner', 'admin', 'ops', 'field_operator']::text[])
    );
CREATE POLICY iot_device_sessions_ops_update ON app.iot_device_sessions
    FOR UPDATE
    USING (
        app.has_tenant_role(tenant_id, ARRAY['tenant_owner', 'admin', 'ops', 'field_operator']::text[])
    )
    WITH CHECK (
        app.has_tenant_role(tenant_id, ARRAY['tenant_owner', 'admin', 'ops', 'field_operator']::text[])
    );

ALTER TABLE app.service_event_logs ENABLE ROW LEVEL SECURITY;
CREATE POLICY service_event_logs_security_read ON app.service_event_logs
    FOR SELECT USING (
        app.has_tenant_role(tenant_id, ARRAY['tenant_owner', 'admin', 'ops', 'security']::text[])
    );
CREATE POLICY service_event_logs_service_insert ON app.service_event_logs
    FOR INSERT WITH CHECK (
        app.can_manage_service_runtime(tenant_id)
        OR app.has_tenant_role(tenant_id, ARRAY['tenant_owner', 'admin', 'ops', 'security']::text[])
    );

COMMENT ON TABLE app.service_api_clients IS 'Trusted service API callers used by internal gateways, device integrations and scheduled jobs.';
COMMENT ON TABLE app.service_jobs IS 'Background execution queue for batch maintenance, retention and data synchronization jobs.';
COMMENT ON TABLE app.h3_library_versions IS 'Pinned H3 library/runtime metadata to keep cell generation and validation reproducible.';
COMMENT ON TABLE app.iot_device_sessions IS 'Telematics session state for authenticated device-to-platform sessions.';
