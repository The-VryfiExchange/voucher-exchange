-- ============================================================================
-- 003: Profile Summary + Admin Input
-- ============================================================================

-- Add summary field to households
ALTER TABLE households ADD COLUMN IF NOT EXISTS summary text;

-- Add field to track who inputted the household (caseworker or admin)
ALTER TABLE households ADD COLUMN IF NOT EXISTS inputted_by uuid REFERENCES profiles(id);
