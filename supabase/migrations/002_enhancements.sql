-- ============================================================================
-- 002: Platform Enhancements
-- Household profile, post-match workflow, status tracking, aftercare
-- ============================================================================

-- ============================================================================
-- 1. HOUSEHOLD PROFILE ENHANCEMENTS
-- ============================================================================

-- Apartment criteria beyond bedrooms
ALTER TABLE households ADD COLUMN IF NOT EXISTS elevator_required boolean DEFAULT false;
ALTER TABLE households ADD COLUMN IF NOT EXISTS floor_preference text; -- 'Ground floor', 'Low floor (1-3)', 'Any floor'
ALTER TABLE households ADD COLUMN IF NOT EXISTS pets text; -- 'None', 'Cat', 'Dog', 'Other'

-- Rent supportability
ALTER TABLE households ADD COLUMN IF NOT EXISTS voucher_payment_standard int DEFAULT 0; -- max the program will pay
ALTER TABLE households ADD COLUMN IF NOT EXISTS rent_supportable_min int DEFAULT 0;
ALTER TABLE households ADD COLUMN IF NOT EXISTS rent_supportable_max int DEFAULT 0;

-- Placement readiness flags (specific blocking issues)
ALTER TABLE households ADD COLUMN IF NOT EXISTS readiness_flags text[] DEFAULT '{}'; -- e.g. ['Pending background check', 'Income recalculation needed']

-- Admin review status
ALTER TABLE households DROP CONSTRAINT IF EXISTS households_stage_check;
ALTER TABLE households ADD CONSTRAINT households_stage_check
  CHECK (stage IN ('Draft', 'Under Review', 'Incomplete', 'Pending', 'Ready', 'Matched', 'Placed'));


-- ============================================================================
-- 2. UNIT / LANDLORD PROFILE ENHANCEMENTS
-- ============================================================================

-- Unit-level tenant criteria
ALTER TABLE units ADD COLUMN IF NOT EXISTS elevator boolean DEFAULT false;
ALTER TABLE units ADD COLUMN IF NOT EXISTS floor int; -- floor number, NULL = any
ALTER TABLE units ADD COLUMN IF NOT EXISTS pets_allowed boolean DEFAULT false;
ALTER TABLE units ADD COLUMN IF NOT EXISTS min_income_ratio numeric(3,1) DEFAULT 0; -- e.g. 2.5x
ALTER TABLE units ADD COLUMN IF NOT EXISTS lease_term text DEFAULT '1 year'; -- '1 year', '2 years', 'Month-to-month'
ALTER TABLE units ADD COLUMN IF NOT EXISTS move_in_date_earliest date;
ALTER TABLE units ADD COLUMN IF NOT EXISTS move_in_date_latest date;
ALTER TABLE units ADD COLUMN IF NOT EXISTS landlord_notes text; -- what landlord wants in a tenant


-- ============================================================================
-- 3. PIPELINE EXPANSION — Guided Closing Workflow
-- ============================================================================

-- Expand pipeline stages
ALTER TABLE pipeline DROP CONSTRAINT IF EXISTS pipeline_stage_check;
ALTER TABLE pipeline ADD CONSTRAINT pipeline_stage_check
  CHECK (stage IN (
    'Interview Requested',
    'Interview Scheduled',
    'Selected',
    'Confirming Apartment',
    'Confirming Rent',
    'Confirming Documents',
    'Submission',
    'Inspection Scheduled',
    'Inspection Passed',
    'Inspection Failed',
    'Approval Pending',
    'Approved',
    'Lease Signing',
    'Lease Signed',
    'Aftercare',
    'Closed',
    'Withdrawn'
  ));

-- Closing checklist per pipeline entry
ALTER TABLE pipeline ADD COLUMN IF NOT EXISTS apartment_confirmed boolean DEFAULT false;
ALTER TABLE pipeline ADD COLUMN IF NOT EXISTS rent_confirmed boolean DEFAULT false;
ALTER TABLE pipeline ADD COLUMN IF NOT EXISTS docs_confirmed boolean DEFAULT false;
ALTER TABLE pipeline ADD COLUMN IF NOT EXISTS caseworker_notified boolean DEFAULT false;
ALTER TABLE pipeline ADD COLUMN IF NOT EXISTS submission_package_ready boolean DEFAULT false;
ALTER TABLE pipeline ADD COLUMN IF NOT EXISTS inspection_date date;
ALTER TABLE pipeline ADD COLUMN IF NOT EXISTS inspection_result text; -- 'Passed', 'Failed', 'Pending'
ALTER TABLE pipeline ADD COLUMN IF NOT EXISTS approval_date date;
ALTER TABLE pipeline ADD COLUMN IF NOT EXISTS lease_signed_date date;
ALTER TABLE pipeline ADD COLUMN IF NOT EXISTS notes text;


-- ============================================================================
-- 4. ACTIVITY LOG — Status Tracking & Transparency
-- ============================================================================

CREATE TABLE IF NOT EXISTS activity_log (
  id            uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  pipeline_id   uuid REFERENCES pipeline(id) ON DELETE CASCADE,
  household_id  uuid REFERENCES households(id) ON DELETE CASCADE,
  unit_id       uuid REFERENCES units(id) ON DELETE CASCADE,
  actor_id      uuid REFERENCES profiles(id),
  action        text NOT NULL, -- 'stage_change', 'doc_updated', 'note_added', 'interview_scheduled', etc.
  details       text, -- human-readable description
  metadata      jsonb DEFAULT '{}', -- extra data (old_stage, new_stage, etc.)
  created_at    timestamptz DEFAULT now()
);

CREATE INDEX IF NOT EXISTS idx_activity_pipeline ON activity_log(pipeline_id);
CREATE INDEX IF NOT EXISTS idx_activity_household ON activity_log(household_id);
CREATE INDEX IF NOT EXISTS idx_activity_created ON activity_log(created_at DESC);

-- RLS for activity log
ALTER TABLE activity_log ENABLE ROW LEVEL SECURITY;

CREATE POLICY "Users see relevant activity" ON activity_log FOR SELECT TO authenticated USING (
  actor_id = auth.uid()
  OR pipeline_id IN (SELECT id FROM pipeline WHERE landlord_id = auth.uid() OR caseworker_id = auth.uid())
  OR household_id IN (SELECT id FROM households WHERE caseworker_id = auth.uid())
  OR unit_id IN (SELECT id FROM units WHERE landlord_id = auth.uid())
);

CREATE POLICY "Authenticated users insert activity" ON activity_log FOR INSERT TO authenticated WITH CHECK (true);

CREATE POLICY "Admins see all activity" ON activity_log FOR SELECT TO authenticated USING (
  (SELECT role FROM profiles WHERE id = auth.uid()) = 'admin'
);


-- ============================================================================
-- 5. AFTERCARE TABLE
-- ============================================================================

CREATE TABLE IF NOT EXISTS aftercare (
  id              uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  pipeline_id     uuid NOT NULL REFERENCES pipeline(id) ON DELETE CASCADE,
  household_id    uuid NOT NULL REFERENCES households(id),
  unit_id         uuid NOT NULL REFERENCES units(id),
  landlord_id     uuid NOT NULL REFERENCES profiles(id),
  caseworker_id   uuid NOT NULL REFERENCES profiles(id),
  status          text NOT NULL DEFAULT 'Active' CHECK (status IN ('Active', 'Monitoring', 'Resolved', 'Closed')),
  wellness_check_date date,
  wellness_check_notes text,
  subsidy_status  text DEFAULT 'Current', -- 'Current', 'Interrupted', 'Resolved'
  arrears_amount  int DEFAULT 0,
  arrears_status  text, -- 'None', 'One-shot applied', 'Pending', 'Resolved'
  support_notes   text,
  next_followup   date,
  created_at      timestamptz DEFAULT now(),
  updated_at      timestamptz DEFAULT now()
);

CREATE INDEX IF NOT EXISTS idx_aftercare_pipeline ON aftercare(pipeline_id);
CREATE INDEX IF NOT EXISTS idx_aftercare_household ON aftercare(household_id);

ALTER TABLE aftercare ENABLE ROW LEVEL SECURITY;

CREATE POLICY "Landlords see own aftercare" ON aftercare FOR SELECT TO authenticated USING (landlord_id = auth.uid());
CREATE POLICY "Caseworkers see own aftercare" ON aftercare FOR SELECT TO authenticated USING (caseworker_id = auth.uid());
CREATE POLICY "Admins see all aftercare" ON aftercare FOR SELECT TO authenticated USING (
  (SELECT role FROM profiles WHERE id = auth.uid()) = 'admin'
);
CREATE POLICY "Insert aftercare" ON aftercare FOR INSERT TO authenticated WITH CHECK (true);
CREATE POLICY "Update aftercare" ON aftercare FOR UPDATE TO authenticated USING (
  landlord_id = auth.uid() OR caseworker_id = auth.uid()
);

-- Trigger for updated_at
CREATE TRIGGER set_updated_at BEFORE UPDATE ON aftercare FOR EACH ROW EXECUTE FUNCTION update_updated_at();


-- ============================================================================
-- 6. UPDATE MATCHING FUNCTION — Include new criteria
-- ============================================================================

CREATE OR REPLACE FUNCTION get_matches_for_unit(p_unit_id uuid)
RETURNS TABLE (
  household_id uuid,
  head_of_household text,
  household_members int,
  voucher_program text,
  voucher_status text,
  authorized_bedrooms text,
  employment_status text,
  monthly_income int,
  ssi_ssdi_amount int,
  tenant_contribution int,
  max_rent int,
  documents text[],
  preferred_neighborhoods text[],
  move_in_timeline text,
  accessibility_needed boolean,
  accessibility_notes text,
  elevator_required boolean,
  floor_preference text,
  pets text,
  voucher_payment_standard int,
  readiness_flags text[],
  notes text,
  stage text,
  caseworker_id uuid,
  created_at timestamptz
)
LANGUAGE sql SECURITY DEFINER
AS $$
  SELECT
    h.id AS household_id,
    h.head_of_household,
    h.household_members,
    h.voucher_program,
    h.voucher_status,
    h.authorized_bedrooms,
    h.employment_status,
    h.monthly_income,
    h.ssi_ssdi_amount,
    h.tenant_contribution,
    h.max_rent,
    h.documents,
    h.preferred_neighborhoods,
    h.move_in_timeline,
    h.accessibility_needed,
    h.accessibility_notes,
    h.elevator_required,
    h.floor_preference,
    h.pets,
    h.voucher_payment_standard,
    h.readiness_flags,
    h.notes,
    h.stage,
    h.caseworker_id,
    h.created_at
  FROM units u
  CROSS JOIN households h
  WHERE
    u.id = p_unit_id
    AND u.landlord_id = auth.uid()
    AND h.stage = 'Ready'
    -- Bedroom match
    AND (
      (h.authorized_bedrooms = 'Studio' AND u.bedrooms = 0) OR
      (h.authorized_bedrooms = '1BR' AND u.bedrooms = 1) OR
      (h.authorized_bedrooms = '2BR' AND u.bedrooms = 2) OR
      (h.authorized_bedrooms = '3BR' AND u.bedrooms = 3) OR
      (h.authorized_bedrooms = '4BR' AND u.bedrooms = 4)
    )
    -- Rent check
    AND h.max_rent >= u.monthly_rent
    -- Neighborhood match
    AND (
      array_length(h.preferred_neighborhoods, 1) IS NULL
      OR u.neighborhood = ANY(h.preferred_neighborhoods)
    )
    -- Program compatibility
    AND (
      'Any' = ANY(u.accepted_programs)
      OR h.voucher_program = ANY(u.accepted_programs)
      OR (h.voucher_program = 'Section 8/HCV' AND 'Section 8' = ANY(u.accepted_programs))
    )
    -- Elevator match (if household requires elevator, unit must have it)
    AND (NOT h.elevator_required OR u.elevator = true)
    -- Pet match (if household has pets, unit must allow)
    AND (h.pets IS NULL OR h.pets = 'None' OR u.pets_allowed = true)
    -- Not already in pipeline
    AND NOT EXISTS (
      SELECT 1 FROM pipeline p
      WHERE p.household_id = h.id AND p.unit_id = u.id
    )
  ORDER BY array_length(h.documents, 1) DESC NULLS LAST;
$$;
