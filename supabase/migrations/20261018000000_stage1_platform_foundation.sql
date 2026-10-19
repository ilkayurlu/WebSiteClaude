-- Stage 1 platform foundation.
-- Requires PostgreSQL 15+ and PostGIS 3. Use the trusted API tier to set
-- request.jwt.claim.sub from a verified JWT; never expose database credentials
-- or accept this setting directly from an untrusted client.

CREATE EXTENSION IF NOT EXISTS pgcrypto;
CREATE EXTENSION IF NOT EXISTS postgis;

CREATE SCHEMA IF NOT EXISTS app;
REVOKE CREATE ON SCHEMA app FROM PUBLIC;
GRANT USAGE ON SCHEMA app TO PUBLIC;

CREATE TABLE app.tenants (
    id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    name text NOT NULL,
    status text NOT NULL DEFAULT 'active'
        CHECK (status IN ('active', 'suspended', 'closed')),
    created_at timestamptz NOT NULL DEFAULT now(),
    updated_at timestamptz NOT NULL DEFAULT now()
);

CREATE TABLE app.users (
    id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    auth_subject text NOT NULL UNIQUE,
    display_name text NOT NULL,
    status text NOT NULL DEFAULT 'active'
        CHECK (status IN ('active', 'suspended', 'closed')),
    created_at timestamptz NOT NULL DEFAULT now(),
    updated_at timestamptz NOT NULL DEFAULT now()
);

CREATE TABLE app.roles (
    name text PRIMARY KEY,
    description text NOT NULL
);

INSERT INTO app.roles (name, description) VALUES
    ('tenant_owner', 'Tenant owner'),
    ('admin', 'Tenant administrator'),
    ('ops', 'Operations control'),
    ('dispatcher', 'Dispatch operator'),
    ('finance', 'Financial operations'),
    ('security', 'Security and audit'),
    ('merchant', 'Store operator'),
    ('customer', 'Customer'),
    ('courier', 'Courier'),
    ('driver', 'City-trip driver'),
    ('field_operator', 'Fleet field operator')
ON CONFLICT (name) DO NOTHING;

CREATE TABLE app.tenant_memberships (
    tenant_id uuid NOT NULL REFERENCES app.tenants(id),
    user_id uuid NOT NULL REFERENCES app.users(id),
    role_name text NOT NULL REFERENCES app.roles(name),
    status text NOT NULL DEFAULT 'active'
        CHECK (status IN ('active', 'suspended', 'ended')),
    created_at timestamptz NOT NULL DEFAULT now(),
    PRIMARY KEY (tenant_id, user_id, role_name)
);

CREATE INDEX tenant_memberships_user_idx
    ON app.tenant_memberships (user_id, tenant_id)
    WHERE status = 'active';

CREATE FUNCTION app.has_tenant_role(target_tenant uuid, allowed_roles text[])
RETURNS boolean
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path = pg_catalog, app
AS $$
    SELECT EXISTS (
        SELECT 1
        FROM tenant_memberships AS m
        JOIN users AS u ON u.id = m.user_id
        WHERE m.tenant_id = target_tenant
          AND m.status = 'active'
          AND u.status = 'active'
          AND u.auth_subject = COALESCE(
              NULLIF(current_setting('request.jwt.claim.sub', true), ''),
              NULLIF(current_setting('request.jwt.claims', true), '')::jsonb ->> 'sub'
          )
          AND m.role_name = ANY (allowed_roles)
    )
$$;

CREATE FUNCTION app.has_tenant_access(target_tenant uuid)
RETURNS boolean
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path = pg_catalog, app
AS $$
    SELECT app.has_tenant_role(
        target_tenant,
        ARRAY[
            'tenant_owner', 'admin', 'ops', 'dispatcher', 'finance',
            'security', 'merchant', 'customer', 'courier', 'driver',
            'field_operator'
        ]::text[]
    )
$$;

CREATE FUNCTION app.current_user_id()
RETURNS uuid
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path = pg_catalog, app
AS $$
    SELECT u.id
    FROM users AS u
    WHERE u.auth_subject = COALESCE(
        NULLIF(current_setting('request.jwt.claim.sub', true), ''),
        NULLIF(current_setting('request.jwt.claims', true), '')::jsonb ->> 'sub'
    )
      AND u.status = 'active'
    LIMIT 1
$$;

ALTER TABLE app.roles ENABLE ROW LEVEL SECURITY;
CREATE POLICY roles_authenticated_read ON app.roles
    FOR SELECT USING (app.current_user_id() IS NOT NULL);

CREATE TABLE app.merchant_locations (
    id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    tenant_id uuid NOT NULL REFERENCES app.tenants(id),
    name text NOT NULL,
    location geography(Point, 4326) NOT NULL,
    status text NOT NULL DEFAULT 'active'
        CHECK (status IN ('active', 'paused', 'closed')),
    created_at timestamptz NOT NULL DEFAULT now(),
    updated_at timestamptz NOT NULL DEFAULT now(),
    UNIQUE (id, tenant_id)
);

CREATE INDEX merchant_locations_geo_idx
    ON app.merchant_locations USING gist (location);
CREATE INDEX merchant_locations_tenant_status_idx
    ON app.merchant_locations (tenant_id, status);

CREATE TABLE app.catalog_items (
    id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    tenant_id uuid NOT NULL REFERENCES app.tenants(id),
    merchant_location_id uuid NOT NULL,
    name text NOT NULL,
    description text,
    price_minor bigint NOT NULL CHECK (price_minor >= 0),
    currency char(3) NOT NULL CHECK (currency ~ '^[A-Z]{3}$'),
    status text NOT NULL DEFAULT 'active'
        CHECK (status IN ('active', 'unavailable', 'archived')),
    created_at timestamptz NOT NULL DEFAULT now(),
    updated_at timestamptz NOT NULL DEFAULT now(),
    UNIQUE (id, tenant_id),
    FOREIGN KEY (merchant_location_id, tenant_id)
        REFERENCES app.merchant_locations (id, tenant_id)
);

CREATE INDEX catalog_items_location_status_idx
    ON app.catalog_items (tenant_id, merchant_location_id, status);

CREATE TABLE app.catalog_inventory (
    tenant_id uuid NOT NULL REFERENCES app.tenants(id),
    catalog_item_id uuid NOT NULL,
    available_quantity integer NOT NULL DEFAULT 0 CHECK (available_quantity >= 0),
    updated_at timestamptz NOT NULL DEFAULT now(),
    PRIMARY KEY (tenant_id, catalog_item_id),
    FOREIGN KEY (catalog_item_id, tenant_id)
        REFERENCES app.catalog_items (id, tenant_id)
);

CREATE TABLE app.service_zones (
    id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    tenant_id uuid NOT NULL REFERENCES app.tenants(id),
    name text NOT NULL,
    zone_type text NOT NULL
        CHECK (zone_type IN (
            'service_area', 'no_ride', 'no_parking', 'speed_limit',
            'surge', 'promotion'
        )),
    status text NOT NULL DEFAULT 'draft'
        CHECK (status IN ('draft', 'active', 'inactive')),
    created_by uuid REFERENCES app.users(id),
    created_at timestamptz NOT NULL DEFAULT now(),
    updated_at timestamptz NOT NULL DEFAULT now(),
    UNIQUE (id, tenant_id)
);

CREATE INDEX service_zones_tenant_status_type_idx
    ON app.service_zones (tenant_id, status, zone_type);

CREATE TABLE app.service_zone_versions (
    id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    tenant_id uuid NOT NULL,
    zone_id uuid NOT NULL,
    version_number integer NOT NULL CHECK (version_number > 0),
    boundary geometry(MultiPolygon, 4326) NOT NULL,
    speed_limit_kph numeric(5, 2)
        CHECK (speed_limit_kph IS NULL OR speed_limit_kph > 0),
    surge_multiplier numeric(6, 3)
        CHECK (surge_multiplier IS NULL OR surge_multiplier >= 1),
    rules jsonb NOT NULL DEFAULT '{}'::jsonb
        CHECK (jsonb_typeof(rules) = 'object'),
    effective_from timestamptz,
    effective_until timestamptz,
    approved_by uuid REFERENCES app.users(id),
    created_at timestamptz NOT NULL DEFAULT now(),
    UNIQUE (zone_id, version_number),
    UNIQUE (id, tenant_id),
    FOREIGN KEY (zone_id, tenant_id)
        REFERENCES app.service_zones (id, tenant_id),
    CHECK (
        effective_until IS NULL
        OR effective_from IS NULL
        OR effective_until > effective_from
    ),
    CHECK (ST_IsValid(boundary))
);

CREATE INDEX service_zone_versions_boundary_idx
    ON app.service_zone_versions USING gist (boundary);
CREATE INDEX service_zone_versions_effective_idx
    ON app.service_zone_versions (tenant_id, effective_from, effective_until);

-- H3 cell IDs are generated by a version-pinned service library. PostGIS
-- remains authoritative for exact polygon membership and boundary checks.
CREATE TABLE app.service_zone_h3_cells (
    tenant_id uuid NOT NULL,
    zone_version_id uuid NOT NULL,
    resolution smallint NOT NULL CHECK (resolution BETWEEN 0 AND 15),
    h3_cell text NOT NULL CHECK (length(h3_cell) BETWEEN 1 AND 32),
    PRIMARY KEY (zone_version_id, resolution, h3_cell),
    FOREIGN KEY (zone_version_id, tenant_id)
        REFERENCES app.service_zone_versions (id, tenant_id)
);

CREATE INDEX service_zone_h3_lookup_idx
    ON app.service_zone_h3_cells (tenant_id, resolution, h3_cell);

CREATE TABLE app.iot_vehicles (
    id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    tenant_id uuid NOT NULL REFERENCES app.tenants(id),
    vehicle_type text NOT NULL
        CHECK (vehicle_type IN ('scooter', 'ebike', 'moped')),
    qr_code_hash bytea NOT NULL,
    battery_percent smallint
        CHECK (battery_percent IS NULL OR battery_percent BETWEEN 0 AND 100),
    estimated_range_meters integer
        CHECK (estimated_range_meters IS NULL OR estimated_range_meters >= 0),
    lock_status text NOT NULL DEFAULT 'locked'
        CHECK (lock_status IN ('locked', 'unlocked', 'unknown', 'fault')),
    health_status text NOT NULL DEFAULT 'available'
        CHECK (health_status IN ('available', 'maintenance', 'fault', 'retired')),
    last_location geography(Point, 4326),
    last_seen_at timestamptz,
    created_at timestamptz NOT NULL DEFAULT now(),
    updated_at timestamptz NOT NULL DEFAULT now(),
    UNIQUE (tenant_id, qr_code_hash),
    UNIQUE (id, tenant_id)
);

CREATE INDEX iot_vehicles_last_location_idx
    ON app.iot_vehicles USING gist (last_location);
CREATE INDEX iot_vehicles_tenant_status_idx
    ON app.iot_vehicles (tenant_id, health_status, lock_status);

CREATE TABLE app.vehicle_devices (
    id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    tenant_id uuid NOT NULL REFERENCES app.tenants(id),
    vehicle_id uuid NOT NULL,
    device_identifier text NOT NULL,
    protocol text NOT NULL CHECK (protocol IN ('ble', 'cellular', 'hybrid')),
    status text NOT NULL DEFAULT 'active'
        CHECK (status IN ('active', 'revoked', 'maintenance')),
    created_at timestamptz NOT NULL DEFAULT now(),
    UNIQUE (tenant_id, device_identifier),
    UNIQUE (id, tenant_id),
    UNIQUE (vehicle_id, tenant_id),
    FOREIGN KEY (vehicle_id, tenant_id)
        REFERENCES app.iot_vehicles (id, tenant_id)
);

CREATE TABLE app.vehicle_telemetry_logs (
    id bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    tenant_id uuid NOT NULL REFERENCES app.tenants(id),
    vehicle_id uuid NOT NULL,
    observed_at timestamptz NOT NULL,
    location geography(Point, 4326) NOT NULL,
    speed_kph numeric(6, 2) CHECK (speed_kph IS NULL OR speed_kph >= 0),
    battery_percent smallint
        CHECK (battery_percent IS NULL OR battery_percent BETWEEN 0 AND 100),
    device_sequence bigint,
    created_at timestamptz NOT NULL DEFAULT now(),
    FOREIGN KEY (vehicle_id, tenant_id)
        REFERENCES app.iot_vehicles (id, tenant_id)
);

CREATE INDEX vehicle_telemetry_vehicle_time_idx
    ON app.vehicle_telemetry_logs (tenant_id, vehicle_id, observed_at DESC);
CREATE INDEX vehicle_telemetry_location_idx
    ON app.vehicle_telemetry_logs USING gist (location);

CREATE TABLE app.shipments (
    id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    tenant_id uuid NOT NULL REFERENCES app.tenants(id),
    customer_user_id uuid NOT NULL REFERENCES app.users(id),
    merchant_location_id uuid,
    public_tracking_token_hash bytea NOT NULL UNIQUE,
    origin_address_ciphertext bytea NOT NULL,
    destination_address_ciphertext bytea NOT NULL,
    origin_location geography(Point, 4326) NOT NULL,
    destination_location geography(Point, 4326) NOT NULL,
    package_size text NOT NULL
        CHECK (package_size IN ('envelope', 'parcel', 'bulky')),
    status text NOT NULL DEFAULT 'quoted'
        CHECK (status IN (
            'quoted', 'pending', 'accepted', 'picked_up', 'in_transit',
            'delivered', 'cancelled', 'failed'
        )),
    quoted_total_minor bigint NOT NULL CHECK (quoted_total_minor >= 0),
    final_total_minor bigint CHECK (final_total_minor IS NULL OR final_total_minor >= 0),
    currency char(3) NOT NULL CHECK (currency ~ '^[A-Z]{3}$'),
    created_at timestamptz NOT NULL DEFAULT now(),
    updated_at timestamptz NOT NULL DEFAULT now(),
    UNIQUE (id, tenant_id),
    FOREIGN KEY (merchant_location_id, tenant_id)
        REFERENCES app.merchant_locations (id, tenant_id)
);

CREATE INDEX shipments_customer_created_idx
    ON app.shipments (tenant_id, customer_user_id, created_at DESC);
CREATE INDEX shipments_status_created_idx
    ON app.shipments (tenant_id, status, created_at);
CREATE INDEX shipments_origin_idx
    ON app.shipments USING gist (origin_location);
CREATE INDEX shipments_destination_idx
    ON app.shipments USING gist (destination_location);

CREATE TABLE app.shipment_items (
    id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    tenant_id uuid NOT NULL,
    shipment_id uuid NOT NULL,
    catalog_item_id uuid,
    item_name text NOT NULL,
    quantity integer NOT NULL CHECK (quantity > 0),
    unit_price_minor bigint NOT NULL CHECK (unit_price_minor >= 0),
    currency char(3) NOT NULL CHECK (currency ~ '^[A-Z]{3}$'),
    created_at timestamptz NOT NULL DEFAULT now(),
    FOREIGN KEY (shipment_id, tenant_id)
        REFERENCES app.shipments (id, tenant_id),
    FOREIGN KEY (catalog_item_id, tenant_id)
        REFERENCES app.catalog_items (id, tenant_id)
);

CREATE INDEX shipment_items_shipment_idx
    ON app.shipment_items (tenant_id, shipment_id);

CREATE TABLE app.shipment_assignments (
    id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    tenant_id uuid NOT NULL,
    shipment_id uuid NOT NULL,
    courier_user_id uuid NOT NULL REFERENCES app.users(id),
    status text NOT NULL DEFAULT 'assigned'
        CHECK (status IN ('assigned', 'accepted', 'rejected', 'completed', 'revoked')),
    assigned_at timestamptz NOT NULL DEFAULT now(),
    ended_at timestamptz,
    created_at timestamptz NOT NULL DEFAULT now(),
    FOREIGN KEY (shipment_id, tenant_id)
        REFERENCES app.shipments (id, tenant_id),
    CHECK (ended_at IS NULL OR ended_at >= assigned_at)
);

CREATE INDEX shipment_assignments_courier_active_idx
    ON app.shipment_assignments (tenant_id, courier_user_id, status);
CREATE INDEX shipment_assignments_shipment_idx
    ON app.shipment_assignments (tenant_id, shipment_id, assigned_at DESC);

CREATE FUNCTION app.can_access_shipment(target_tenant uuid, target_shipment uuid)
RETURNS boolean
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path = pg_catalog, app
AS $$
    SELECT app.has_tenant_access(target_tenant)
       AND (
           app.has_tenant_role(
               target_tenant,
               ARRAY['tenant_owner', 'admin', 'ops', 'dispatcher']::text[]
           )
        OR EXISTS (
            SELECT 1
            FROM shipments AS s
            WHERE s.id = target_shipment
              AND s.tenant_id = target_tenant
              AND s.customer_user_id = app.current_user_id()
        )
        OR EXISTS (
            SELECT 1
            FROM shipment_assignments AS a
            WHERE a.shipment_id = target_shipment
              AND a.tenant_id = target_tenant
              AND a.courier_user_id = app.current_user_id()
              AND a.status IN ('assigned', 'accepted')
        )
       )
$$;

CREATE TABLE app.shipment_events (
    id bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    tenant_id uuid NOT NULL,
    shipment_id uuid NOT NULL,
    event_type text NOT NULL,
    event_data jsonb NOT NULL DEFAULT '{}'::jsonb
        CHECK (jsonb_typeof(event_data) = 'object'),
    actor_user_id uuid REFERENCES app.users(id),
    occurred_at timestamptz NOT NULL DEFAULT now(),
    FOREIGN KEY (shipment_id, tenant_id)
        REFERENCES app.shipments (id, tenant_id)
);

CREATE INDEX shipment_events_timeline_idx
    ON app.shipment_events (tenant_id, shipment_id, occurred_at);

CREATE TABLE app.mobility_rides (
    id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    tenant_id uuid NOT NULL REFERENCES app.tenants(id),
    rider_user_id uuid NOT NULL REFERENCES app.users(id),
    vehicle_id uuid NOT NULL,
    status text NOT NULL DEFAULT 'requested'
        CHECK (status IN (
            'requested', 'unlocking', 'in_progress', 'ending',
            'completed', 'cancelled', 'failed'
        )),
    started_at timestamptz,
    ended_at timestamptz,
    start_location geography(Point, 4326),
    end_location geography(Point, 4326),
    start_photo_object_key text,
    end_photo_object_key text,
    total_minor bigint CHECK (total_minor IS NULL OR total_minor >= 0),
    currency char(3) CHECK (currency IS NULL OR currency ~ '^[A-Z]{3}$'),
    created_at timestamptz NOT NULL DEFAULT now(),
    updated_at timestamptz NOT NULL DEFAULT now(),
    UNIQUE (id, tenant_id),
    FOREIGN KEY (vehicle_id, tenant_id)
        REFERENCES app.iot_vehicles (id, tenant_id),
    CHECK (
        (total_minor IS NULL AND currency IS NULL)
        OR (total_minor IS NOT NULL AND currency IS NOT NULL)
    ),
    CHECK (ended_at IS NULL OR started_at IS NULL OR ended_at >= started_at)
);

CREATE INDEX mobility_rides_rider_created_idx
    ON app.mobility_rides (tenant_id, rider_user_id, created_at DESC);
CREATE INDEX mobility_rides_status_idx
    ON app.mobility_rides (tenant_id, status, created_at);

CREATE TABLE app.mobility_ride_events (
    id bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    tenant_id uuid NOT NULL,
    ride_id uuid NOT NULL,
    event_type text NOT NULL,
    event_data jsonb NOT NULL DEFAULT '{}'::jsonb
        CHECK (jsonb_typeof(event_data) = 'object'),
    actor_user_id uuid REFERENCES app.users(id),
    occurred_at timestamptz NOT NULL DEFAULT now(),
    FOREIGN KEY (ride_id, tenant_id)
        REFERENCES app.mobility_rides (id, tenant_id)
);

CREATE INDEX mobility_ride_events_timeline_idx
    ON app.mobility_ride_events (tenant_id, ride_id, occurred_at);

CREATE TABLE app.city_trips (
    id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    tenant_id uuid NOT NULL REFERENCES app.tenants(id),
    passenger_user_id uuid NOT NULL REFERENCES app.users(id),
    driver_user_id uuid REFERENCES app.users(id),
    status text NOT NULL DEFAULT 'requested'
        CHECK (status IN (
            'requested', 'matched', 'driver_arriving', 'in_progress',
            'completed', 'cancelled', 'failed'
        )),
    pickup_address_ciphertext bytea NOT NULL,
    dropoff_address_ciphertext bytea NOT NULL,
    pickup_location geography(Point, 4326) NOT NULL,
    dropoff_location geography(Point, 4326) NOT NULL,
    route geometry(LineString, 4326),
    quoted_fare_minor bigint NOT NULL CHECK (quoted_fare_minor >= 0),
    final_fare_minor bigint CHECK (final_fare_minor IS NULL OR final_fare_minor >= 0),
    currency char(3) NOT NULL CHECK (currency ~ '^[A-Z]{3}$'),
    requested_at timestamptz NOT NULL DEFAULT now(),
    started_at timestamptz,
    ended_at timestamptz,
    created_at timestamptz NOT NULL DEFAULT now(),
    updated_at timestamptz NOT NULL DEFAULT now(),
    UNIQUE (id, tenant_id),
    CHECK (ended_at IS NULL OR started_at IS NULL OR ended_at >= started_at)
);

CREATE INDEX city_trips_passenger_created_idx
    ON app.city_trips (tenant_id, passenger_user_id, created_at DESC);
CREATE INDEX city_trips_driver_created_idx
    ON app.city_trips (tenant_id, driver_user_id, created_at DESC);
CREATE INDEX city_trips_status_requested_idx
    ON app.city_trips (tenant_id, status, requested_at);
CREATE INDEX city_trips_pickup_idx
    ON app.city_trips USING gist (pickup_location);
CREATE INDEX city_trips_route_idx
    ON app.city_trips USING gist (route);

CREATE TABLE app.city_trip_safety_events (
    id bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    tenant_id uuid NOT NULL,
    trip_id uuid NOT NULL,
    event_type text NOT NULL
        CHECK (event_type IN ('safety_button', 'incident_report', 'support_request')),
    status text NOT NULL DEFAULT 'open'
        CHECK (status IN ('open', 'acknowledged', 'resolved', 'false_alarm')),
    details_ciphertext bytea,
    created_by uuid NOT NULL REFERENCES app.users(id),
    created_at timestamptz NOT NULL DEFAULT now(),
    resolved_at timestamptz,
    FOREIGN KEY (trip_id, tenant_id)
        REFERENCES app.city_trips (id, tenant_id),
    CHECK (resolved_at IS NULL OR resolved_at >= created_at)
);

CREATE INDEX city_trip_safety_open_idx
    ON app.city_trip_safety_events (tenant_id, status, created_at);

CREATE TABLE app.city_trip_events (
    id bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    tenant_id uuid NOT NULL,
    trip_id uuid NOT NULL,
    event_type text NOT NULL,
    event_data jsonb NOT NULL DEFAULT '{}'::jsonb
        CHECK (jsonb_typeof(event_data) = 'object'),
    actor_user_id uuid REFERENCES app.users(id),
    occurred_at timestamptz NOT NULL DEFAULT now(),
    FOREIGN KEY (trip_id, tenant_id)
        REFERENCES app.city_trips (id, tenant_id)
);

CREATE INDEX city_trip_events_timeline_idx
    ON app.city_trip_events (tenant_id, trip_id, occurred_at);

CREATE TABLE app.field_tasks (
    id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    tenant_id uuid NOT NULL REFERENCES app.tenants(id),
    task_type text NOT NULL
        CHECK (task_type IN ('battery_swap', 'vehicle_recovery', 'inspection', 'repair')),
    vehicle_id uuid,
    assigned_user_id uuid REFERENCES app.users(id),
    status text NOT NULL DEFAULT 'open'
        CHECK (status IN ('open', 'assigned', 'in_progress', 'completed', 'cancelled')),
    location geography(Point, 4326) NOT NULL,
    reward_minor bigint NOT NULL CHECK (reward_minor >= 0),
    currency char(3) NOT NULL CHECK (currency ~ '^[A-Z]{3}$'),
    created_at timestamptz NOT NULL DEFAULT now(),
    updated_at timestamptz NOT NULL DEFAULT now(),
    completed_at timestamptz,
    UNIQUE (id, tenant_id),
    FOREIGN KEY (vehicle_id, tenant_id)
        REFERENCES app.iot_vehicles (id, tenant_id),
    CHECK (completed_at IS NULL OR completed_at >= created_at)
);

CREATE INDEX field_tasks_pool_idx
    ON app.field_tasks (tenant_id, status, task_type, created_at);
CREATE INDEX field_tasks_location_idx
    ON app.field_tasks USING gist (location);
CREATE INDEX field_tasks_assignee_idx
    ON app.field_tasks (tenant_id, assigned_user_id, status);

CREATE TABLE app.proof_of_deliveries (
    id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    tenant_id uuid NOT NULL REFERENCES app.tenants(id),
    shipment_id uuid,
    mobility_ride_id uuid,
    city_trip_id uuid,
    field_task_id uuid,
    media_object_key text,
    otp_hash bytea,
    captured_location geography(Point, 4326),
    recipient_signature_object_key text,
    created_by uuid NOT NULL REFERENCES app.users(id),
    created_at timestamptz NOT NULL DEFAULT now(),
    CHECK (num_nonnulls(shipment_id, mobility_ride_id, city_trip_id, field_task_id) = 1),
    FOREIGN KEY (shipment_id, tenant_id)
        REFERENCES app.shipments (id, tenant_id),
    FOREIGN KEY (mobility_ride_id, tenant_id)
        REFERENCES app.mobility_rides (id, tenant_id),
    FOREIGN KEY (city_trip_id, tenant_id)
        REFERENCES app.city_trips (id, tenant_id),
    FOREIGN KEY (field_task_id, tenant_id)
        REFERENCES app.field_tasks (id, tenant_id)
);

CREATE INDEX proof_shipment_idx ON app.proof_of_deliveries (tenant_id, shipment_id);
CREATE INDEX proof_mobility_ride_idx ON app.proof_of_deliveries (tenant_id, mobility_ride_id);
CREATE INDEX proof_city_trip_idx ON app.proof_of_deliveries (tenant_id, city_trip_id);
CREATE INDEX proof_field_task_idx ON app.proof_of_deliveries (tenant_id, field_task_id);

CREATE TABLE app.wallets (
    id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    tenant_id uuid NOT NULL REFERENCES app.tenants(id),
    user_id uuid NOT NULL REFERENCES app.users(id),
    currency char(3) NOT NULL CHECK (currency ~ '^[A-Z]{3}$'),
    status text NOT NULL DEFAULT 'active'
        CHECK (status IN ('active', 'frozen', 'closed')),
    created_at timestamptz NOT NULL DEFAULT now(),
    updated_at timestamptz NOT NULL DEFAULT now(),
    UNIQUE (tenant_id, user_id, currency),
    UNIQUE (id, tenant_id, currency)
);

CREATE TABLE app.ledger_accounts (
    id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    tenant_id uuid NOT NULL REFERENCES app.tenants(id),
    wallet_id uuid,
    account_code text NOT NULL,
    account_type text NOT NULL
        CHECK (account_type IN ('wallet', 'platform', 'merchant_payable', 'courier_payable')),
    currency char(3) NOT NULL CHECK (currency ~ '^[A-Z]{3}$'),
    created_at timestamptz NOT NULL DEFAULT now(),
    UNIQUE (tenant_id, account_code, currency),
    UNIQUE (id, tenant_id, currency),
    FOREIGN KEY (wallet_id, tenant_id, currency)
        REFERENCES app.wallets (id, tenant_id, currency),
    CHECK ((account_type = 'wallet') = (wallet_id IS NOT NULL))
);

CREATE TABLE app.ledger_transactions (
    id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    tenant_id uuid NOT NULL REFERENCES app.tenants(id),
    idempotency_key text NOT NULL,
    transaction_type text NOT NULL,
    status text NOT NULL DEFAULT 'posted' CHECK (status = 'posted'),
    currency char(3) NOT NULL CHECK (currency ~ '^[A-Z]{3}$'),
    reversal_of_id uuid,
    metadata jsonb NOT NULL DEFAULT '{}'::jsonb
        CHECK (jsonb_typeof(metadata) = 'object'),
    created_at timestamptz NOT NULL DEFAULT now(),
    UNIQUE (tenant_id, idempotency_key),
    UNIQUE (id, tenant_id, currency),
    FOREIGN KEY (reversal_of_id, tenant_id, currency)
        REFERENCES app.ledger_transactions (id, tenant_id, currency),
    CHECK (reversal_of_id IS NULL OR reversal_of_id <> id)
);

CREATE UNIQUE INDEX ledger_transactions_one_reversal_idx
    ON app.ledger_transactions (tenant_id, reversal_of_id)
    WHERE reversal_of_id IS NOT NULL;

CREATE TABLE app.ledger_entries (
    id bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    tenant_id uuid NOT NULL,
    transaction_id uuid NOT NULL,
    account_id uuid NOT NULL,
    currency char(3) NOT NULL CHECK (currency ~ '^[A-Z]{3}$'),
    amount_minor bigint NOT NULL CHECK (amount_minor <> 0),
    created_at timestamptz NOT NULL DEFAULT now(),
    FOREIGN KEY (transaction_id, tenant_id, currency)
        REFERENCES app.ledger_transactions (id, tenant_id, currency),
    FOREIGN KEY (account_id, tenant_id, currency)
        REFERENCES app.ledger_accounts (id, tenant_id, currency)
);

CREATE INDEX ledger_entries_transaction_idx
    ON app.ledger_entries (tenant_id, transaction_id);
CREATE INDEX ledger_entries_account_time_idx
    ON app.ledger_entries (tenant_id, account_id, created_at DESC);

CREATE FUNCTION app.assert_ledger_transaction_balanced()
RETURNS trigger
LANGUAGE plpgsql
SET search_path = pg_catalog, app
AS $$
DECLARE
    target_id uuid;
    reversed_transaction_id uuid;
    entry_count bigint;
    balance numeric;
BEGIN
    target_id := CASE
        WHEN TG_TABLE_NAME = 'ledger_transactions'
            THEN (to_jsonb(NEW) ->> 'id')::uuid
        ELSE (to_jsonb(NEW) ->> 'transaction_id')::uuid
    END;

    SELECT count(*), COALESCE(sum(amount_minor), 0)
      INTO entry_count, balance
      FROM ledger_entries
     WHERE transaction_id = target_id;

    IF entry_count < 2 OR balance <> 0 THEN
        RAISE EXCEPTION 'Ledger transaction % must have at least two balanced entries', target_id
            USING ERRCODE = '23514';
    END IF;

    SELECT reversal_of_id
      INTO reversed_transaction_id
      FROM ledger_transactions
     WHERE id = target_id;

    IF reversed_transaction_id IS NOT NULL AND (
        EXISTS (
            SELECT account_id, currency, -sum(amount_minor) AS amount_minor
              FROM ledger_entries
             WHERE transaction_id = reversed_transaction_id
             GROUP BY account_id, currency
            EXCEPT
            SELECT account_id, currency, sum(amount_minor) AS amount_minor
              FROM ledger_entries
             WHERE transaction_id = target_id
             GROUP BY account_id, currency
        )
        OR EXISTS (
            SELECT account_id, currency, sum(amount_minor) AS amount_minor
              FROM ledger_entries
             WHERE transaction_id = target_id
             GROUP BY account_id, currency
            EXCEPT
            SELECT account_id, currency, -sum(amount_minor) AS amount_minor
              FROM ledger_entries
             WHERE transaction_id = reversed_transaction_id
             GROUP BY account_id, currency
        )
    ) THEN
        RAISE EXCEPTION 'Ledger reversal % must exactly reverse transaction %',
            target_id, reversed_transaction_id
            USING ERRCODE = '23514';
    END IF;
    RETURN NULL;
END
$$;

CREATE CONSTRAINT TRIGGER ledger_transaction_balance_check
AFTER INSERT ON app.ledger_transactions
DEFERRABLE INITIALLY DEFERRED
FOR EACH ROW EXECUTE FUNCTION app.assert_ledger_transaction_balanced();

CREATE CONSTRAINT TRIGGER ledger_entry_balance_check
AFTER INSERT ON app.ledger_entries
DEFERRABLE INITIALLY DEFERRED
FOR EACH ROW EXECUTE FUNCTION app.assert_ledger_transaction_balanced();

CREATE TABLE app.payout_requests (
    id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    tenant_id uuid NOT NULL REFERENCES app.tenants(id),
    payee_user_id uuid NOT NULL REFERENCES app.users(id),
    amount_minor bigint NOT NULL CHECK (amount_minor > 0),
    currency char(3) NOT NULL CHECK (currency ~ '^[A-Z]{3}$'),
    status text NOT NULL DEFAULT 'requested'
        CHECK (status IN ('requested', 'approved', 'rejected', 'processing', 'paid', 'failed')),
    requested_at timestamptz NOT NULL DEFAULT now(),
    reviewed_by uuid REFERENCES app.users(id),
    reviewed_at timestamptz,
    created_at timestamptz NOT NULL DEFAULT now(),
    CHECK (reviewed_at IS NULL OR reviewed_at >= requested_at)
);

CREATE INDEX payout_requests_review_idx
    ON app.payout_requests (tenant_id, status, requested_at);

CREATE TABLE app.idempotency_records (
    id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    tenant_id uuid NOT NULL REFERENCES app.tenants(id),
    actor_user_id uuid REFERENCES app.users(id),
    idempotency_key text NOT NULL,
    request_hash bytea NOT NULL,
    response_status smallint,
    response_body jsonb,
    created_at timestamptz NOT NULL DEFAULT now(),
    expires_at timestamptz NOT NULL,
    UNIQUE (tenant_id, idempotency_key),
    CHECK (expires_at > created_at)
);

CREATE INDEX idempotency_expiry_idx ON app.idempotency_records (expires_at);

CREATE TABLE app.media_assets (
    id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    tenant_id uuid NOT NULL REFERENCES app.tenants(id),
    object_key text NOT NULL,
    media_type text NOT NULL,
    byte_size bigint CHECK (byte_size IS NULL OR byte_size >= 0),
    checksum_sha256 bytea,
    uploaded_by uuid REFERENCES app.users(id),
    created_at timestamptz NOT NULL DEFAULT now(),
    retention_until timestamptz,
    UNIQUE (tenant_id, object_key)
);

CREATE TABLE app.audit_logs (
    id bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    tenant_id uuid NOT NULL REFERENCES app.tenants(id),
    actor_user_id uuid REFERENCES app.users(id),
    action text NOT NULL,
    resource_type text NOT NULL,
    resource_id text,
    source_ip inet,
    metadata jsonb NOT NULL DEFAULT '{}'::jsonb
        CHECK (jsonb_typeof(metadata) = 'object'),
    occurred_at timestamptz NOT NULL DEFAULT now()
);

CREATE INDEX audit_logs_tenant_time_idx
    ON app.audit_logs (tenant_id, occurred_at DESC);
CREATE INDEX audit_logs_resource_idx
    ON app.audit_logs (tenant_id, resource_type, resource_id, occurred_at DESC);

CREATE FUNCTION app.deny_append_only_mutation()
RETURNS trigger
LANGUAGE plpgsql
SET search_path = pg_catalog, app
AS $$
BEGIN
    RAISE EXCEPTION '% is append-only', TG_TABLE_NAME
        USING ERRCODE = '55000';
END
$$;

DO $$
DECLARE
    table_name text;
BEGIN
    FOREACH table_name IN ARRAY ARRAY[
        'shipment_events',
        'mobility_ride_events',
        'city_trip_events',
        'vehicle_telemetry_logs',
        'service_zone_versions',
        'service_zone_h3_cells',
        'ledger_transactions',
        'ledger_entries',
        'audit_logs'
    ]
    LOOP
        EXECUTE format(
            'CREATE TRIGGER %I_append_only
             BEFORE UPDATE OR DELETE ON app.%I
             FOR EACH ROW EXECUTE FUNCTION app.deny_append_only_mutation()',
            table_name,
            table_name
        );
        EXECUTE format(
            'CREATE TRIGGER %I_no_truncate
             BEFORE TRUNCATE ON app.%I
             FOR EACH STATEMENT EXECUTE FUNCTION app.deny_append_only_mutation()',
            table_name,
            table_name
        );
    END LOOP;
END
$$;

CREATE FUNCTION app.can_access_trip(target_tenant uuid, target_trip uuid)
RETURNS boolean
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path = pg_catalog, app
AS $$
    SELECT app.has_tenant_access(target_tenant)
       AND (
           app.has_tenant_role(
               target_tenant,
               ARRAY['tenant_owner', 'admin', 'ops', 'dispatcher', 'security']::text[]
           )
        OR EXISTS (
            SELECT 1
            FROM city_trips AS t
            WHERE t.id = target_trip
              AND t.tenant_id = target_tenant
              AND app.current_user_id() IN (t.passenger_user_id, t.driver_user_id)
        )
       )
$$;

CREATE FUNCTION app.can_access_mobility_ride(target_tenant uuid, target_ride uuid)
RETURNS boolean
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path = pg_catalog, app
AS $$
    SELECT app.has_tenant_access(target_tenant)
       AND (
           app.has_tenant_role(
               target_tenant,
               ARRAY['tenant_owner', 'admin', 'ops', 'dispatcher', 'security']::text[]
           )
        OR EXISTS (
            SELECT 1
            FROM mobility_rides AS r
            WHERE r.id = target_ride
              AND r.tenant_id = target_tenant
              AND r.rider_user_id = app.current_user_id()
        )
       )
$$;

CREATE FUNCTION app.can_access_field_task(target_tenant uuid, target_task uuid)
RETURNS boolean
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path = pg_catalog, app
AS $$
    SELECT app.has_tenant_access(target_tenant)
       AND (
           app.has_tenant_role(
               target_tenant,
               ARRAY['tenant_owner', 'admin', 'ops', 'dispatcher']::text[]
           )
        OR EXISTS (
            SELECT 1
            FROM field_tasks AS t
            WHERE t.id = target_task
              AND t.tenant_id = target_tenant
              AND t.assigned_user_id = app.current_user_id()
        )
       )
$$;

CREATE FUNCTION app.can_access_wallet(target_tenant uuid, target_wallet uuid)
RETURNS boolean
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path = pg_catalog, app
AS $$
    SELECT app.has_tenant_access(target_tenant)
       AND (
           app.has_tenant_role(
               target_tenant,
               ARRAY['tenant_owner', 'admin', 'finance', 'security']::text[]
           )
        OR EXISTS (
            SELECT 1
            FROM wallets AS w
            WHERE w.id = target_wallet
              AND w.tenant_id = target_tenant
              AND w.user_id = app.current_user_id()
        )
       )
$$;

CREATE FUNCTION app.can_access_ledger_transaction(target_tenant uuid, target_transaction uuid)
RETURNS boolean
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path = pg_catalog, app
AS $$
    SELECT app.has_tenant_role(
               target_tenant,
               ARRAY['tenant_owner', 'admin', 'finance', 'security']::text[]
           )
        OR EXISTS (
            SELECT 1
            FROM ledger_entries AS e
            JOIN ledger_accounts AS a
              ON a.id = e.account_id
             AND a.tenant_id = e.tenant_id
             AND a.currency = e.currency
            WHERE e.transaction_id = target_transaction
              AND e.tenant_id = target_tenant
              AND a.wallet_id IS NOT NULL
              AND app.can_access_wallet(target_tenant, a.wallet_id)
        )
$$;

CREATE FUNCTION app.can_access_proof(
    target_tenant uuid,
    target_shipment uuid,
    target_mobility_ride uuid,
    target_city_trip uuid,
    target_field_task uuid
)
RETURNS boolean
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path = pg_catalog, app
AS $$
    SELECT
        (target_shipment IS NOT NULL
            AND app.can_access_shipment(target_tenant, target_shipment))
        OR (target_mobility_ride IS NOT NULL
            AND app.can_access_mobility_ride(target_tenant, target_mobility_ride))
        OR (target_city_trip IS NOT NULL
            AND app.can_access_trip(target_tenant, target_city_trip))
        OR (target_field_task IS NOT NULL
            AND app.can_access_field_task(target_tenant, target_field_task))
$$;

ALTER TABLE app.tenants ENABLE ROW LEVEL SECURITY;
CREATE POLICY tenants_member_read ON app.tenants
    FOR SELECT USING (app.has_tenant_access(id));

ALTER TABLE app.users ENABLE ROW LEVEL SECURITY;
CREATE POLICY users_self_read ON app.users
    FOR SELECT USING (auth_subject = COALESCE(
        NULLIF(current_setting('request.jwt.claim.sub', true), ''),
        NULLIF(current_setting('request.jwt.claims', true), '')::jsonb ->> 'sub'
    ));

ALTER TABLE app.tenant_memberships ENABLE ROW LEVEL SECURITY;
CREATE POLICY memberships_self_or_admin_read ON app.tenant_memberships
    FOR SELECT USING (
        user_id = app.current_user_id()
        OR app.has_tenant_role(tenant_id, ARRAY['tenant_owner', 'admin']::text[])
    );

ALTER TABLE app.merchant_locations ENABLE ROW LEVEL SECURITY;
CREATE POLICY merchant_locations_member_read ON app.merchant_locations
    FOR SELECT USING (app.has_tenant_access(tenant_id));
CREATE POLICY merchant_locations_ops_write ON app.merchant_locations
    FOR INSERT WITH CHECK (
        app.has_tenant_role(tenant_id, ARRAY['tenant_owner', 'admin', 'ops', 'merchant']::text[])
    );
CREATE POLICY merchant_locations_ops_update ON app.merchant_locations
    FOR UPDATE
    USING (app.has_tenant_role(tenant_id, ARRAY['tenant_owner', 'admin', 'ops', 'merchant']::text[]))
    WITH CHECK (app.has_tenant_role(tenant_id, ARRAY['tenant_owner', 'admin', 'ops', 'merchant']::text[]));

ALTER TABLE app.catalog_items ENABLE ROW LEVEL SECURITY;
CREATE POLICY catalog_items_member_read ON app.catalog_items
    FOR SELECT USING (app.has_tenant_access(tenant_id));
CREATE POLICY catalog_items_merchant_write ON app.catalog_items
    FOR INSERT WITH CHECK (
        app.has_tenant_role(tenant_id, ARRAY['tenant_owner', 'admin', 'merchant']::text[])
    );
CREATE POLICY catalog_items_merchant_update ON app.catalog_items
    FOR UPDATE
    USING (app.has_tenant_role(tenant_id, ARRAY['tenant_owner', 'admin', 'merchant']::text[]))
    WITH CHECK (app.has_tenant_role(tenant_id, ARRAY['tenant_owner', 'admin', 'merchant']::text[]));

ALTER TABLE app.catalog_inventory ENABLE ROW LEVEL SECURITY;
CREATE POLICY catalog_inventory_member_read ON app.catalog_inventory
    FOR SELECT USING (app.has_tenant_access(tenant_id));
CREATE POLICY catalog_inventory_merchant_write ON app.catalog_inventory
    FOR INSERT WITH CHECK (
        app.has_tenant_role(tenant_id, ARRAY['tenant_owner', 'admin', 'merchant']::text[])
    );
CREATE POLICY catalog_inventory_merchant_update ON app.catalog_inventory
    FOR UPDATE
    USING (app.has_tenant_role(tenant_id, ARRAY['tenant_owner', 'admin', 'merchant']::text[]))
    WITH CHECK (app.has_tenant_role(tenant_id, ARRAY['tenant_owner', 'admin', 'merchant']::text[]));

ALTER TABLE app.service_zones ENABLE ROW LEVEL SECURITY;
CREATE POLICY service_zones_member_read ON app.service_zones
    FOR SELECT USING (app.has_tenant_access(tenant_id));
CREATE POLICY service_zones_ops_write ON app.service_zones
    FOR INSERT WITH CHECK (
        app.has_tenant_role(tenant_id, ARRAY['tenant_owner', 'admin', 'ops']::text[])
    );
CREATE POLICY service_zones_ops_update ON app.service_zones
    FOR UPDATE
    USING (app.has_tenant_role(tenant_id, ARRAY['tenant_owner', 'admin', 'ops']::text[]))
    WITH CHECK (app.has_tenant_role(tenant_id, ARRAY['tenant_owner', 'admin', 'ops']::text[]));

ALTER TABLE app.service_zone_versions ENABLE ROW LEVEL SECURITY;
CREATE POLICY zone_versions_member_read ON app.service_zone_versions
    FOR SELECT USING (app.has_tenant_access(tenant_id));
CREATE POLICY zone_versions_ops_write ON app.service_zone_versions
    FOR INSERT WITH CHECK (
        app.has_tenant_role(tenant_id, ARRAY['tenant_owner', 'admin', 'ops']::text[])
    );

ALTER TABLE app.service_zone_h3_cells ENABLE ROW LEVEL SECURITY;
CREATE POLICY zone_h3_member_read ON app.service_zone_h3_cells
    FOR SELECT USING (app.has_tenant_access(tenant_id));
CREATE POLICY zone_h3_ops_write ON app.service_zone_h3_cells
    FOR INSERT WITH CHECK (
        app.has_tenant_role(tenant_id, ARRAY['tenant_owner', 'admin', 'ops']::text[])
    );

ALTER TABLE app.iot_vehicles ENABLE ROW LEVEL SECURITY;
CREATE POLICY iot_vehicles_ops_read ON app.iot_vehicles
    FOR SELECT USING (
        app.has_tenant_role(
            tenant_id,
            ARRAY['tenant_owner', 'admin', 'ops', 'dispatcher', 'field_operator', 'security']::text[]
        )
    );
CREATE POLICY iot_vehicles_ops_write ON app.iot_vehicles
    FOR INSERT WITH CHECK (
        app.has_tenant_role(tenant_id, ARRAY['tenant_owner', 'admin', 'ops', 'field_operator']::text[])
    );
CREATE POLICY iot_vehicles_ops_update ON app.iot_vehicles
    FOR UPDATE
    USING (
        app.has_tenant_role(tenant_id, ARRAY['tenant_owner', 'admin', 'ops', 'field_operator']::text[])
    )
    WITH CHECK (
        app.has_tenant_role(tenant_id, ARRAY['tenant_owner', 'admin', 'ops', 'field_operator']::text[])
    );

ALTER TABLE app.vehicle_devices ENABLE ROW LEVEL SECURITY;
CREATE POLICY vehicle_devices_ops_read ON app.vehicle_devices
    FOR SELECT USING (
        app.has_tenant_role(
            tenant_id,
            ARRAY['tenant_owner', 'admin', 'ops', 'dispatcher', 'field_operator', 'security']::text[]
        )
    );

ALTER TABLE app.vehicle_telemetry_logs ENABLE ROW LEVEL SECURITY;
CREATE POLICY vehicle_telemetry_ops_read ON app.vehicle_telemetry_logs
    FOR SELECT USING (
        app.has_tenant_role(
            tenant_id,
            ARRAY['tenant_owner', 'admin', 'ops', 'dispatcher', 'field_operator', 'security']::text[]
        )
    );

ALTER TABLE app.shipments ENABLE ROW LEVEL SECURITY;
CREATE POLICY shipments_authorized_read ON app.shipments
    FOR SELECT USING (app.can_access_shipment(tenant_id, id));

ALTER TABLE app.shipment_items ENABLE ROW LEVEL SECURITY;
CREATE POLICY shipment_items_authorized_read ON app.shipment_items
    FOR SELECT USING (app.can_access_shipment(tenant_id, shipment_id));

ALTER TABLE app.shipment_assignments ENABLE ROW LEVEL SECURITY;
CREATE POLICY shipment_assignments_authorized_read ON app.shipment_assignments
    FOR SELECT USING (app.can_access_shipment(tenant_id, shipment_id));
CREATE POLICY shipment_assignments_ops_create ON app.shipment_assignments
    FOR INSERT WITH CHECK (
        app.has_tenant_role(tenant_id, ARRAY['tenant_owner', 'admin', 'ops', 'dispatcher']::text[])
    );
CREATE POLICY shipment_assignments_ops_update ON app.shipment_assignments
    FOR UPDATE
    USING (app.has_tenant_role(tenant_id, ARRAY['tenant_owner', 'admin', 'ops', 'dispatcher']::text[]))
    WITH CHECK (app.has_tenant_role(tenant_id, ARRAY['tenant_owner', 'admin', 'ops', 'dispatcher']::text[]));

ALTER TABLE app.shipment_events ENABLE ROW LEVEL SECURITY;
CREATE POLICY shipment_events_authorized_read ON app.shipment_events
    FOR SELECT USING (app.can_access_shipment(tenant_id, shipment_id));

ALTER TABLE app.mobility_rides ENABLE ROW LEVEL SECURITY;
CREATE POLICY mobility_rides_authorized_read ON app.mobility_rides
    FOR SELECT USING (app.can_access_mobility_ride(tenant_id, id));

ALTER TABLE app.mobility_ride_events ENABLE ROW LEVEL SECURITY;
CREATE POLICY mobility_ride_events_authorized_read ON app.mobility_ride_events
    FOR SELECT USING (app.can_access_mobility_ride(tenant_id, ride_id));

ALTER TABLE app.city_trips ENABLE ROW LEVEL SECURITY;
CREATE POLICY city_trips_authorized_read ON app.city_trips
    FOR SELECT USING (app.can_access_trip(tenant_id, id));

ALTER TABLE app.city_trip_safety_events ENABLE ROW LEVEL SECURITY;
CREATE POLICY city_trip_safety_authorized_read ON app.city_trip_safety_events
    FOR SELECT USING (app.can_access_trip(tenant_id, trip_id));
CREATE POLICY city_trip_safety_participant_create ON app.city_trip_safety_events
    FOR INSERT WITH CHECK (
        created_by = app.current_user_id()
        AND status = 'open'
        AND app.can_access_trip(tenant_id, trip_id)
    );

ALTER TABLE app.city_trip_events ENABLE ROW LEVEL SECURITY;
CREATE POLICY city_trip_events_authorized_read ON app.city_trip_events
    FOR SELECT USING (app.can_access_trip(tenant_id, trip_id));

ALTER TABLE app.field_tasks ENABLE ROW LEVEL SECURITY;
CREATE POLICY field_tasks_authorized_read ON app.field_tasks
    FOR SELECT USING (
        app.can_access_field_task(tenant_id, id)
        OR app.has_tenant_role(tenant_id, ARRAY['field_operator']::text[])
    );

ALTER TABLE app.proof_of_deliveries ENABLE ROW LEVEL SECURITY;
CREATE POLICY proofs_authorized_read ON app.proof_of_deliveries
    FOR SELECT USING (
        app.can_access_proof(
            tenant_id,
            shipment_id,
            mobility_ride_id,
            city_trip_id,
            field_task_id
        )
    );

ALTER TABLE app.wallets ENABLE ROW LEVEL SECURITY;
CREATE POLICY wallets_owner_or_finance_read ON app.wallets
    FOR SELECT USING (app.can_access_wallet(tenant_id, id));

ALTER TABLE app.ledger_accounts ENABLE ROW LEVEL SECURITY;
CREATE POLICY ledger_accounts_finance_read ON app.ledger_accounts
    FOR SELECT USING (
        app.has_tenant_role(tenant_id, ARRAY['tenant_owner', 'admin', 'finance', 'security']::text[])
        OR (wallet_id IS NOT NULL AND app.can_access_wallet(tenant_id, wallet_id))
    );

ALTER TABLE app.ledger_transactions ENABLE ROW LEVEL SECURITY;
CREATE POLICY ledger_transactions_authorized_read ON app.ledger_transactions
    FOR SELECT USING (app.can_access_ledger_transaction(tenant_id, id));

ALTER TABLE app.ledger_entries ENABLE ROW LEVEL SECURITY;
CREATE POLICY ledger_entries_authorized_read ON app.ledger_entries
    FOR SELECT USING (
        app.has_tenant_role(tenant_id, ARRAY['tenant_owner', 'admin', 'finance', 'security']::text[])
        OR EXISTS (
            SELECT 1 FROM app.ledger_accounts AS a
            WHERE a.id = ledger_entries.account_id
              AND a.tenant_id = ledger_entries.tenant_id
              AND a.currency = ledger_entries.currency
              AND a.wallet_id IS NOT NULL
              AND app.can_access_wallet(tenant_id, a.wallet_id)
        )
    );

ALTER TABLE app.payout_requests ENABLE ROW LEVEL SECURITY;
CREATE POLICY payout_requests_owner_or_finance_read ON app.payout_requests
    FOR SELECT USING (
        app.has_tenant_access(tenant_id)
        AND (
            payee_user_id = app.current_user_id()
            OR app.has_tenant_role(tenant_id, ARRAY['tenant_owner', 'admin', 'finance']::text[])
        )
    );
CREATE POLICY payout_requests_finance_update ON app.payout_requests
    FOR UPDATE
    USING (app.has_tenant_role(tenant_id, ARRAY['tenant_owner', 'admin', 'finance']::text[]))
    WITH CHECK (app.has_tenant_role(tenant_id, ARRAY['tenant_owner', 'admin', 'finance']::text[]));

ALTER TABLE app.idempotency_records ENABLE ROW LEVEL SECURITY;
ALTER TABLE app.media_assets ENABLE ROW LEVEL SECURITY;
ALTER TABLE app.audit_logs ENABLE ROW LEVEL SECURITY;
CREATE POLICY audit_logs_security_read ON app.audit_logs
    FOR SELECT USING (
        app.has_tenant_role(tenant_id, ARRAY['tenant_owner', 'admin', 'security']::text[])
    );

-- No user-facing policies are defined for idempotency records or private
-- media metadata. Access is intentionally denied until a trusted service path
-- is implemented and separately reviewed.
