-- Prerequisites for Drizzle schema push
-- Run this against Supabase before `bunx drizzle-kit push`
--
-- IMPORTANT: After running `drizzle-kit push`, check for camelCase columns:
--   SELECT table_name, column_name FROM information_schema.columns
--   WHERE table_schema = 'public' AND column_name ~ '[A-Z]';
-- Drizzle may create camelCase columns (e.g. "baseBalance") instead of
-- snake_case ("base_balance"). Rename them manually:
--   ALTER TABLE bank_accounts RENAME COLUMN "baseBalance" TO base_balance;
--   ALTER TABLE customers RENAME COLUMN "billingEmail" TO billing_email;
--   ALTER TABLE invoice_products RENAME COLUMN "isActive" TO is_active;
--   ALTER TABLE transactions RENAME COLUMN "baseAmount" TO base_amount;

-- Extensions
CREATE EXTENSION IF NOT EXISTS "pg_trgm" WITH SCHEMA "public";
CREATE EXTENSION IF NOT EXISTS "pgcrypto" WITH SCHEMA "extensions";
CREATE EXTENSION IF NOT EXISTS "unaccent" WITH SCHEMA "public";
CREATE EXTENSION IF NOT EXISTS "uuid-ossp" WITH SCHEMA "extensions";
CREATE EXTENSION IF NOT EXISTS "vector" WITH SCHEMA "extensions";

-- Private schema for RLS helper functions
CREATE SCHEMA IF NOT EXISTS "private";
ALTER SCHEMA "private" OWNER TO "postgres";

-- RLS helper: get teams for authenticated user
CREATE OR REPLACE FUNCTION "private"."get_teams_for_authenticated_user"() RETURNS SETOF "uuid"
    LANGUAGE "sql" STABLE SECURITY DEFINER
    SET "search_path" TO 'public'
    AS $$
  select team_id
  from users_on_team
  where user_id = auth.uid()
$$;

-- RLS helper: get invites for authenticated user
CREATE OR REPLACE FUNCTION "private"."get_invites_for_authenticated_user"() RETURNS SETOF "uuid"
    LANGUAGE "sql" STABLE SECURITY DEFINER
    SET "search_path" TO 'public'
    AS $$
  select team_id
  from user_invites
  where email = auth.jwt() ->> 'email'
$$;

-- Extract product names from JSON array
CREATE OR REPLACE FUNCTION "public"."extract_product_names"("products_json" "json") RETURNS "text"
    LANGUAGE "plpgsql" IMMUTABLE
    AS $$
begin
    return (
        select string_agg(value, ',')
        from json_array_elements_text(products_json) as arr(value)
    );
end;
$$;

-- Generate random ID
CREATE OR REPLACE FUNCTION "public"."generate_id"("size" integer) RETURNS "text"
    LANGUAGE "plpgsql"
    AS $$
DECLARE
  characters TEXT := 'ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789';
  bytes BYTEA := gen_random_bytes(size);
  l INT := length(characters);
  i INT := 0;
  output TEXT := '';
BEGIN
  WHILE i < size LOOP
    output := output || substr(characters, get_byte(bytes, i) % l + 1, 1);
    i := i + 1;
  END LOOP;
  RETURN lower(output);
END;
$$;

-- Generate inbox ID
CREATE OR REPLACE FUNCTION "public"."generate_inbox"("size" integer) RETURNS "text"
    LANGUAGE "plpgsql"
    AS $$
DECLARE
  characters TEXT := 'ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789';
  bytes BYTEA := extensions.gen_random_bytes(size);
  l INT := length(characters);
  i INT := 0;
  output TEXT := '';
BEGIN
  WHILE i < size LOOP
    output := output || substr(characters, get_byte(bytes, i) % l + 1, 1);
    i := i + 1;
  END LOOP;
  RETURN lower(output);
END;
$$;

-- Full-text search for inbox (3 overloads)
CREATE OR REPLACE FUNCTION "public"."generate_inbox_fts"("display_name" "text", "products_json" "json") RETURNS "tsvector"
    LANGUAGE "plpgsql" IMMUTABLE
    AS $$
begin
    return to_tsvector('english', coalesce(display_name, '') || ' ' || (
        select string_agg(value, ',')
        from json_array_elements_text(products_json) as arr(value)
    ));
end;
$$;

CREATE OR REPLACE FUNCTION "public"."generate_inbox_fts"("display_name_text" "text", "product_names" "text") RETURNS "tsvector"
    LANGUAGE "plpgsql" IMMUTABLE
    AS $$
begin
    return to_tsvector('english', coalesce(display_name_text, '') || ' ' || coalesce(product_names, ''));
end;
$$;

CREATE OR REPLACE FUNCTION "public"."generate_inbox_fts"("display_name_text" "text", "product_names" "text", "amount" numeric, "due_date" "date") RETURNS "tsvector"
    LANGUAGE "plpgsql" IMMUTABLE
    AS $$
begin
    return to_tsvector('english', coalesce(display_name_text, '') || ' ' || coalesce(product_names, '') || ' ' || coalesce(amount::text, '') || ' ' || due_date);
end;
$$;

-- Nanoid functions (used for ID generation)
CREATE OR REPLACE FUNCTION "public"."nanoid_optimized"("size" integer, "alphabet" "text", "mask" integer, "step" integer) RETURNS "text"
    LANGUAGE "plpgsql" PARALLEL SAFE
    AS $$
DECLARE
    idBuilder      text := '';
    counter        int  := 0;
    bytes          bytea;
    alphabetIndex  int;
    alphabetArray  text[];
    alphabetLength int  := 64;
BEGIN
    alphabetArray := regexp_split_to_array(alphabet, '');
    alphabetLength := array_length(alphabetArray, 1);
    LOOP
        bytes := extensions.gen_random_bytes(step);
        FOR counter IN 0..step - 1
            LOOP
                alphabetIndex := (get_byte(bytes, counter) & mask) + 1;
                IF alphabetIndex <= alphabetLength THEN
                    idBuilder := idBuilder || alphabetArray[alphabetIndex];
                    IF length(idBuilder) = size THEN
                        RETURN idBuilder;
                    END IF;
                END IF;
            END LOOP;
    END LOOP;
END
$$;

CREATE OR REPLACE FUNCTION "public"."nanoid"("size" integer DEFAULT 21, "alphabet" "text" DEFAULT '_-0123456789abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ'::"text", "additionalbytesfactor" double precision DEFAULT 1.6) RETURNS "text"
    LANGUAGE "plpgsql" PARALLEL SAFE
    AS $$
DECLARE
    alphabetArray  text[];
    alphabetLength int := 64;
    mask           int := 63;
    step           int := 34;
BEGIN
    IF size IS NULL OR size < 1 THEN
        RAISE EXCEPTION 'The size must be defined and greater than 0!';
    END IF;
    IF alphabet IS NULL OR length(alphabet) = 0 OR length(alphabet) > 255 THEN
        RAISE EXCEPTION 'The alphabet can''t be undefined, zero or bigger than 255 symbols!';
    END IF;
    IF additionalBytesFactor IS NULL OR additionalBytesFactor < 1 THEN
        RAISE EXCEPTION 'The additional bytes factor can''t be less than 1!';
    END IF;
    alphabetArray := regexp_split_to_array(alphabet, '');
    alphabetLength := array_length(alphabetArray, 1);
    mask := (2 << cast(floor(log(alphabetLength - 1) / log(2)) as int)) - 1;
    step := cast(ceil(additionalBytesFactor * mask * size / alphabetLength) AS int);
    IF step > 1024 THEN
        step := 1024;
    END IF;
    RETURN nanoid_optimized(size, alphabet, mask, step);
END
$$;

-- Slug generation
CREATE OR REPLACE FUNCTION "public"."slugify"("value" "text") RETURNS "text"
    LANGUAGE "sql" IMMUTABLE STRICT
    AS $$
  SELECT trim(both '-' from regexp_replace(
    lower(unaccent(trim(value))),
    '[^a-z0-9\\-_]+', '-', 'gi'
  ))
$$;

CREATE OR REPLACE FUNCTION "public"."generate_slug_from_name"() RETURNS "trigger"
    LANGUAGE "plpgsql"
    AS $$begin
  if new.system is true then
    return new;
  end if;
  new.slug := public.slugify(new.name);
  return new;
end$$;

-- HMAC generation (used for webhooks)
CREATE OR REPLACE FUNCTION "public"."generate_hmac"("secret_key" "text", "message" "text") RETURNS "text"
    LANGUAGE "plpgsql"
    AS $$
BEGIN
  RETURN encode(
    extensions.hmac(message::bytea, secret_key::bytea, 'sha256'),
    'hex'
  );
END;
$$;
