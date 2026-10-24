---
kind: mdbase.type
name: task
version: 1
match: { path_glob: "tasks/*.md" }
x-record-schema:
  awaiting_human: { field: status, values: [waiting] }
schema:
  dialect: json-schema-2020-12
  value:
    type: object
    additionalProperties: false
    required: [status, title]
    properties:
      status: { enum: [waiting, doing, done] }
      title:  { type: string, minLength: 1 }
---
# task

Test fixture for `frontmatter-schema-check count`: total 5, awaiting 2 (status waiting), doing 1, done 2. TEMPLATE.md and README.md are not records.
