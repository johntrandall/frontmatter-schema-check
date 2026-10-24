---
kind: mdbase.type
name: book
version: 1
match: { path_glob: "books/*.md" }
schema:
  dialect: json-schema-2020-12
  value:
    type: object
    additionalProperties: false
    required: [type, title, format, year]
    properties:
      type:   { const: book }
      title:  { type: string, minLength: 1 }
      format: { enum: [hardcover, paperback, ebook] }
      year:   { type: integer, minimum: 1450 }
      isbn:   { type: [string, "null"], pattern: "^[0-9-]{10,17}$" }
      tags:   { type: array, items: { type: string } }
      read:   { type: boolean }
---
# book

Test fixture: twenty clean book records. tests/run.sh copies this folder and breaks copies on purpose.
