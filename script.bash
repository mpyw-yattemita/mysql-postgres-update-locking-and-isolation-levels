#!/usr/bin/env bash

my() {
    MYSQL_PWD=password mysql --host mysql --port 3306 --user user --database exam
}
pg() {
    PGPASSWORD=password psql --host postgres --port 5432 --user user --dbname exam
}

escape() {
  sed -e 's/[]\/$*.^[]/\\&/g'
}
replace_sleep() {
  cmd="$1"
  sleep_time="$2"
  sed "s/%%SLEEP_FN%%/$(sleep_fn "$cmd" "$sleep_time" | escape)/"
}
sleep_fn() {
    local cmd="$1"
    local sec="$2"
    local my_fn="sleep($sec)";
    local pg_fn="(pg_sleep($sec)::text != '')::int";
    local var="${cmd}_fn"
    echo "${!var}"
}
begin_with_tx() {
    local cmd="$1"
    local isolation="$2"
    local my_begin="SET TRANSACTION ISOLATION LEVEL $isolation; BEGIN"
    local pg_begin="BEGIN; SET TRANSACTION ISOLATION LEVEL $isolation"
    local var="${cmd}_begin"
    echo "${!var}"
}
perform() {
    local cmd="$1"
    local isolation="$2"
    local sql="$3"
    local replaced="$(replace_sleep "$cmd" N <<< "$sql")"
    echo -e "CMD:$cmd ISOLATION:$isolation\n\n[SQL]\n$replaced\n"
    "$cmd" <<< 'SELECT * FROM products;'
    perform_one_with_prefix "A: " 2 "$cmd" "$isolation" "$sql" &
    perform_one_with_prefix "B: " 4 "$cmd" "$isolation" "$sql" &
    wait
    "$cmd" <<< 'SELECT * FROM products;'
    "$cmd" <<< 'UPDATE products SET remaining_amount=1;'
    echo
}
perform_one_with_prefix() {
    local prefix="$1"
    local sleep_time="$2"
    local cmd="$3"
    local isolation="$4"
    local sql="$5"
    exec > >(trap "" INT TERM; sed "s/^/$prefix/")
    exec 2> >(trap "" INT TERM; sed "s/^/$prefix/" >&2)
    local replaced="$(replace_sleep "$cmd" "$sleep_time" <<< "$sql")"
    "$cmd" <<< \
"$(begin_with_tx "$cmd" "$isolation");
$replaced
COMMIT;"
}

cmds=(
  pg
  my
)
isolations=(
  'READ UNCOMMITTED'
  'READ COMMITTED'
  'REPEATABLE READ'
  'SERIALIZABLE'
)
sqls=(
'-- NORMAL, DELAY BEFORE SELECTION --
SELECT %%SLEEP_FN%%;
UPDATE products
SET remaining_amount=remaining_amount-1
WHERE id=1 AND remaining_amount>0;'

'-- NORMAL, DELAY WHILE UPDATING --
UPDATE products
SET remaining_amount=remaining_amount-1+(SELECT %%SLEEP_FN%%)
WHERE id=1 AND remaining_amount>0;'

'-- SUBQUERY WHERE, DELAY BEFORE SELECTION --
SELECT %%SLEEP_FN%%;
UPDATE products
SET remaining_amount=remaining_amount-1
WHERE EXISTS(
  SELECT * FROM (
    SELECT * FROM products WHERE id=1 AND remaining_amount>0
  ) tmp
);'

'-- SUBQUERY WHERE, DELAY WHILE UPDATING --
UPDATE products
SET remaining_amount=remaining_amount-1+(SELECT %%SLEEP_FN%%)
WHERE EXISTS(
  SELECT * FROM (
    SELECT * FROM products WHERE id=1 AND remaining_amount>0
  ) tmp
);'

'-- SUBQUERY SET, DELAY BEFORE SELECTION --
SELECT %%SLEEP_FN%%;
UPDATE products
SET remaining_amount=(SELECT remaining_amount FROM (SELECT * FROM products WHERE id=1) tmp)-1
WHERE id=1 AND remaining_amount>0;'

'-- SUBQUERY SET DELAY WHILE UPDATING --
UPDATE products
SET remaining_amount=(SELECT remaining_amount FROM (SELECT * FROM products WHERE id=1) tmp)-1+(SELECT %%SLEEP_FN%%)
WHERE id=1 AND remaining_amount>0;'
)

for cmd in "${cmds[@]}"; do
    for sql in "${sqls[@]}"; do
        for isolation in "${isolations[@]}"; do
            if [[ "$cmd" == pg ]] && [[ "$isolation" == 'READ UNCOMMITTED' ]]; then
                continue
            fi
            perform "$cmd" "$isolation" "$sql"
        done
    done
done
