-- KB Articles schema (Phase 1)
-- Idempotent-ish: use IF NOT EXISTS where possible; RLS policies created conditionally.
-- Assumes pgvector extension already installed if embeddings will be used later.

CREATE TABLE IF NOT EXISTS kb_articles (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  slug text UNIQUE,
  title text NOT NULL,
  content text NOT NULL,
  species text[] DEFAULT '{}',
  tags text[] DEFAULT '{}',
  language text DEFAULT 'es',
  status text NOT NULL DEFAULT 'draft' CHECK (status IN ('draft','published','archived')),
  version int NOT NULL DEFAULT 1,
  author_user_id uuid NOT NULL,
  published_at timestamptz,
  search_tsv tsvector,
  embedding vector(1536), -- nullable until embedding generated
  embedding_version int,
  created_at timestamptz NOT NULL DEFAULT now(),
  updated_at timestamptz NOT NULL DEFAULT now()
);

-- Basic indexes
CREATE INDEX IF NOT EXISTS idx_kb_articles_status_published_at ON kb_articles(status, published_at);
CREATE INDEX IF NOT EXISTS idx_kb_articles_search_tsv ON kb_articles USING GIN (search_tsv);
CREATE INDEX IF NOT EXISTS idx_kb_articles_tags ON kb_articles USING GIN (tags);
CREATE INDEX IF NOT EXISTS idx_kb_articles_species ON kb_articles USING GIN (species);

-- Slug helper: if slug is null, derive from title (simple transliteration & suffix uniqueness)
CREATE OR REPLACE FUNCTION kb_slugify(raw text) RETURNS text LANGUAGE plpgsql AS $$
DECLARE
  base text;
  candidate text;
  i int := 1;
BEGIN
  base := lower(regexp_replace(coalesce(raw,''), '[^a-zA-Z0-9]+', '-', 'g'));
  base := regexp_replace(base, '^-|-$', '', 'g');
  IF base = '' THEN
    base := 'article';
  END IF;
  candidate := base;
  WHILE EXISTS (SELECT 1 FROM kb_articles WHERE slug = candidate) LOOP
    i := i + 1;
    candidate := base || '-' || i::text;
  END LOOP;
  RETURN candidate;
END;$$;

-- Maintain slug & search_tsv before insert/update
CREATE OR REPLACE FUNCTION kb_articles_biu() RETURNS trigger LANGUAGE plpgsql AS $$
DECLARE
  txt text;
BEGIN
  IF NEW.slug IS NULL THEN
    NEW.slug := kb_slugify(NEW.title);
  END IF;
  NEW.updated_at := now();
  txt := coalesce(NEW.title,'') || ' ' || coalesce(NEW.content,'') || ' ' || array_to_string(NEW.tags,' ') || ' ' || array_to_string(NEW.species,' ');
  NEW.search_tsv := es_en_tsv(txt);
  RETURN NEW;
END;$$;

DO $$
BEGIN
  BEGIN
    CREATE TRIGGER trg_kb_articles_biu BEFORE INSERT OR UPDATE ON kb_articles
    FOR EACH ROW EXECUTE FUNCTION kb_articles_biu();
  EXCEPTION WHEN duplicate_object THEN END;
END$$;

-- RLS policies
ALTER TABLE kb_articles ENABLE ROW LEVEL SECURITY;

-- Helper function to detect admin role from JWT claims JSON
CREATE OR REPLACE FUNCTION is_admin() RETURNS boolean LANGUAGE sql AS $$
  SELECT coalesce(current_setting('request.jwt.claims', true)::jsonb ? 'admin', false);
$$;

-- Policy: published articles are visible to anyone
DO $$
BEGIN
  BEGIN
    CREATE POLICY kb_articles_select_published ON kb_articles
      FOR SELECT USING (status = 'published');
  EXCEPTION WHEN duplicate_object THEN END;
END$$;

-- Policy: author or admin can see non-archived drafts
DO $$
BEGIN
  BEGIN
    CREATE POLICY kb_articles_select_author ON kb_articles
      FOR SELECT USING (
        (status != 'archived') AND (
          author_user_id::text = coalesce((current_setting('request.jwt.claims', true)::jsonb ->> 'sub'), '')
          OR is_admin()
        )
      );
  EXCEPTION WHEN duplicate_object THEN END;
END$$;

-- Insert: only authenticated (treat any sub) – could restrict further to admin/vet later
DO $$
BEGIN
  BEGIN
    CREATE POLICY kb_articles_insert ON kb_articles
      FOR INSERT WITH CHECK (
        author_user_id::text = (current_setting('request.jwt.claims', true)::jsonb ->> 'sub') OR is_admin()
      );
  EXCEPTION WHEN duplicate_object THEN END;
END$$;

-- Update: author or admin
DO $$
BEGIN
  BEGIN
    CREATE POLICY kb_articles_update ON kb_articles
      FOR UPDATE USING (
        author_user_id::text = (current_setting('request.jwt.claims', true)::jsonb ->> 'sub') OR is_admin()
      ) WITH CHECK (
        author_user_id::text = (current_setting('request.jwt.claims', true)::jsonb ->> 'sub') OR is_admin()
      );
  EXCEPTION WHEN duplicate_object THEN END;
END$$;

-- (Optional) Delete: restrict to admin only for now
DO $$
BEGIN
  BEGIN
    CREATE POLICY kb_articles_delete ON kb_articles
      FOR DELETE USING (is_admin());
  EXCEPTION WHEN duplicate_object THEN END;
END$$;
