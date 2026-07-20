WITH "mut" AS (INSERT INTO "public"."article" ("id", "title", "published") VALUES (10, cast($1 as "text"), DEFAULT), (11, cast($2 as "text"), true) RETURNING "id" AS "id") SELECT coalesce(json_agg(row_to_json("mut")), '[]') AS "rows" FROM "mut";

{
    1: String(
        "first",
    ),
    2: String(
        "second",
    ),
}
