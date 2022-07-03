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
  sleep_time_if_a=$([[ "$2" -eq 1 ]] && printf %s 2 || printf %s 0)
  sed "s/%%SLEEP_DELAY%%/$(sleep_fn "$cmd" "$sleep_time" | escape)/g" \
  | sed "s/%%SLEEP_IF_A%%/$(sleep_fn "$cmd" "$sleep_time_if_a" | escape)/g"
}
replace_user() {
  cmd="$1"
  user="$2"
  sed "s/%%USER%%/$(printf %s "$user" | escape)/g"
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
    sleep 0.3
    perform_one A 1 "$cmd" "$isolation" "$sql" &
    perform_one B 2 "$cmd" "$isolation" "$sql" &
    wait
    sleep 0.3
    "$cmd" <<< 'SELECT * FROM products;'
    sleep 0.3
    "$cmd" <<< 'UPDATE products SET remaining_amount=1,referencing_amount_A=NULL,referencing_amount_B=NULL;'
    echo
}
perform_one() {
    local user="$1"
    local sleep_time="$2"
    local cmd="$3"
    local isolation="$4"
    local sql="$5"
    exec > >(trap "" INT TERM; sed "s/^/$user: /")
    exec 2> >(trap "" INT TERM; sed "s/^/$user: /" >&2)
    local replaced
    replaced="$(replace_sleep "$cmd" "$sleep_time" <<< "$sql")"
    replaced="$(replace_user "$cmd" "$user" <<< "$replaced")"
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
'-- NORMAL, DELAY BEFORE READ --
SELECT %%SLEEP_DELAY%%;
UPDATE products
SET referencing_amount_%%USER%%=remaining_amount, remaining_amount=remaining_amount-1
WHERE id=1 AND remaining_amount>0;
SELECT %%SLEEP_IF_A%%;'

'-- NORMAL, DELAY ON PRE-WRITE --
UPDATE products
SET referencing_amount_%%USER%%=(SELECT %%SLEEP_DELAY%%)+remaining_amount, remaining_amount=remaining_amount-1
WHERE id=1 AND remaining_amount>0;
SELECT %%SLEEP_IF_A%%;'

'-- NORMAL, DELAY ON POST-WRITE --
UPDATE products
SET referencing_amount_%%USER%%=remaining_amount, remaining_amount=remaining_amount-1+(SELECT %%SLEEP_DELAY%%)
WHERE id=1 AND remaining_amount>0;
SELECT %%SLEEP_IF_A%%;'

'-- SUBQUERY WHERE, DELAY BEFORE READ --
SELECT %%SLEEP_DELAY%%;
UPDATE products
SET referencing_amount_%%USER%%=remaining_amount, remaining_amount=remaining_amount-1
WHERE EXISTS(
  SELECT * FROM (
    SELECT * FROM products WHERE id=1 AND remaining_amount>0
  ) tmp
);
SELECT %%SLEEP_IF_A%%;'

'-- SUBQUERY WHERE, DELAY ON PRE-WRITE --
UPDATE products
SET referencing_amount_%%USER%%=(SELECT %%SLEEP_DELAY%%)+remaining_amount, remaining_amount=remaining_amount-1
WHERE EXISTS(
  SELECT * FROM (
    SELECT * FROM products WHERE id=1 AND remaining_amount>0
  ) tmp
);
SELECT %%SLEEP_IF_A%%;'

'-- SUBQUERY WHERE, DELAY ON POST-WRITE --
UPDATE products
SET referencing_amount_%%USER%%=+remaining_amount, remaining_amount=remaining_amount-1+(SELECT %%SLEEP_DELAY%%)
WHERE EXISTS(
  SELECT * FROM (
    SELECT * FROM products WHERE id=1 AND remaining_amount>0
  ) tmp
);
SELECT %%SLEEP_IF_A%%;'

'-- SUBQUERY SET, DELAY BEFORE READ --
SELECT %%SLEEP_DELAY%%;
UPDATE products
SET
  referencing_amount_%%USER%%=(SELECT remaining_amount FROM (SELECT * FROM products WHERE id=1) tmp1),
  remaining_amount=(SELECT remaining_amount FROM (SELECT * FROM products WHERE id=1) tmp2)-1
WHERE id=1 AND remaining_amount>0;
SELECT %%SLEEP_IF_A%%;'

'-- SUBQUERY SET DELAY ON PRE-WRITE --
UPDATE products
SET
  referencing_amount_%%USER%%=(SELECT %%SLEEP_DELAY%%)+(SELECT remaining_amount FROM (SELECT * FROM products WHERE id=1) tmp1),
  remaining_amount=(SELECT remaining_amount FROM (SELECT * FROM products WHERE id=1) tmp2)-1
WHERE id=1 AND remaining_amount>0;
SELECT %%SLEEP_IF_A%%;'

'-- SUBQUERY SET DELAY ON POST-WRITE --
UPDATE products
SET
  referencing_amount_%%USER%%=(SELECT remaining_amount FROM (SELECT * FROM products WHERE id=1) tmp1),
  remaining_amount=(SELECT remaining_amount FROM (SELECT * FROM products WHERE id=1) tmp2)-1+(SELECT %%SLEEP_DELAY%%)
WHERE id=1 AND remaining_amount>0;
SELECT %%SLEEP_IF_A%%;'
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
