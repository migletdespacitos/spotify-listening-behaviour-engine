{#
    Override dbt's default schema naming.

    Default dbt behaviour concatenates target schema + custom schema
    (e.g. `main_staging`). For a single-user local DuckDB warehouse, clean
    layer names (`staging`, `intermediate`, `marts`) are easier to query from
    Python and Tableau, so we use the custom schema name verbatim.
#}
{% macro generate_schema_name(custom_schema_name, node) -%}
    {%- if custom_schema_name is none -%}
        {{ target.schema }}
    {%- else -%}
        {{ custom_schema_name | trim }}
    {%- endif -%}
{%- endmacro %}
