{#
    Generic test: the combination of `columns` must be unique.
    (A dependency-free version of dbt_utils.unique_combination_of_columns.)
#}
{% test unique_combination_of_columns(model, columns) %}

select
    {{ columns | join(', ') }},
    count(*) as n_rows
from {{ model }}
group by {{ columns | join(', ') }}
having count(*) > 1

{% endtest %}
