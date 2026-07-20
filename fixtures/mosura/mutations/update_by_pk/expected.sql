WITH "mut" AS (UPDATE "public"."article" SET "title" = cast($1 as "text"), "published" = false WHERE ("id" = 10) RETURNING "id" AS "id", "title" AS "title", "published" AS "published") SELECT coalesce(json_agg(row_to_json("mut")), '[]') AS "rows" FROM "mut";

{
    1: String(
        "updated title",
    ),
}
