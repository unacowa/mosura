WITH "mut" AS (INSERT INTO "public"."article" ("id", "title", "author_id") VALUES (10, cast($1 as "text"), 1) RETURNING "id" AS "id", "title" AS "title") SELECT coalesce(json_agg(row_to_json("mut")), '[]') AS "rows" FROM "mut";

{
    1: String(
        "new article",
    ),
}
