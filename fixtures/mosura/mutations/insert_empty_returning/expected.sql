WITH "mut" AS (INSERT INTO "public"."article" ("id", "title") VALUES (12, cast($1 as "text")) RETURNING 1 AS "__count") SELECT coalesce(json_agg(row_to_json("mut")), '[]') AS "rows" FROM "mut";

{
    1: String(
        "no returning",
    ),
}
