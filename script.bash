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
  sleep_time_before_commit="$3"
  sed "s/%%SLEEP_DELAY%%/$(sleep_fn "$cmd" "$sleep_time" | escape)/g" \
  | sed "s/%%SLEEP_BEFORE_COMMIT%%/$(sleep_fn "$cmd" "$sleep_time_before_commit" | escape)/g"
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
    local commit_delay="$3"
    local sql="$4"
    local replaced="$(replace_sleep "$cmd" "1|2" "$commit_delay|0" <<< "$sql")"
    echo -e "CMD:$cmd ISOLATION:$isolation\n\n[SQL]\n$replaced\n"
    "$cmd" <<< 'SELECT * FROM products;'
    perform_one A 1 "$commit_delay" "$cmd" "$isolation" "$sql" &
    perform_one B 2 0               "$cmd" "$isolation" "$sql" &
    wait
    "$cmd" <<< 'SELECT * FROM products;'
    "$cmd" <<< 'UPDATE products SET remaining_amount=1,referencing_amount_A=NULL,referencing_amount_B=NULL;'
    echo
}
perform_one() {
    local user="$1"
    local sleep_time="$2"
    local commit_delay="$3"
    local cmd="$4"
    local isolation="$5"
    local sql="$6"
    exec > >(trap "" INT TERM; sed "s/^/$user: /")
    exec 2> >(trap "" INT TERM; sed "s/^/$user: /" >&2)
    local replaced
    replaced="$(replace_sleep "$cmd" "$sleep_time" "$commit_delay" <<< "$sql")"
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
commit_delays=(
  2
  0
)
sqls=(
'-- NORMAL, DELAY BEFORE READ --
SELECT %%SLEEP_DELAY%%;
UPDATE products
SET referencing_amount_%%USER%%=remaining_amount, remaining_amount=remaining_amount-1
WHERE id=1 AND remaining_amount>0;
SELECT %%SLEEP_BEFORE_COMMIT%%;'

'-- NORMAL, DELAY ON PRE-WRITE --
UPDATE products
SET referencing_amount_%%USER%%=(SELECT %%SLEEP_DELAY%%)+remaining_amount, remaining_amount=remaining_amount-1
WHERE id=1 AND remaining_amount>0;
SELECT %%SLEEP_BEFORE_COMMIT%%;'

'-- NORMAL, DELAY ON POST-WRITE --
UPDATE products
SET referencing_amount_%%USER%%=remaining_amount, remaining_amount=remaining_amount-1+(SELECT %%SLEEP_DELAY%%)
WHERE id=1 AND remaining_amount>0;
SELECT %%SLEEP_BEFORE_COMMIT%%;'

'-- SUBQUERY WHERE, DELAY BEFORE READ --
SELECT %%SLEEP_DELAY%%;
UPDATE products
SET referencing_amount_%%USER%%=remaining_amount, remaining_amount=remaining_amount-1
WHERE EXISTS(
  SELECT * FROM (
    SELECT * FROM products WHERE id=1 AND remaining_amount>0
  ) tmp
);
SELECT %%SLEEP_BEFORE_COMMIT%%;'

'-- SUBQUERY WHERE, DELAY ON PRE-WRITE --
UPDATE products
SET referencing_amount_%%USER%%=(SELECT %%SLEEP_DELAY%%)+remaining_amount, remaining_amount=remaining_amount-1
WHERE EXISTS(
  SELECT * FROM (
    SELECT * FROM products WHERE id=1 AND remaining_amount>0
  ) tmp
);
SELECT %%SLEEP_BEFORE_COMMIT%%;'

'-- SUBQUERY WHERE, DELAY ON POST-WRITE --
UPDATE products
SET referencing_amount_%%USER%%=+remaining_amount, remaining_amount=remaining_amount-1+(SELECT %%SLEEP_DELAY%%)
WHERE EXISTS(
  SELECT * FROM (
    SELECT * FROM products WHERE id=1 AND remaining_amount>0
  ) tmp
);
SELECT %%SLEEP_BEFORE_COMMIT%%;'

'-- SUBQUERY SET, DELAY BEFORE READ --
SELECT %%SLEEP_DELAY%%;
UPDATE products
SET
  referencing_amount_%%USER%%=(SELECT remaining_amount FROM (SELECT * FROM products WHERE id=1) tmp1),
  remaining_amount=(SELECT remaining_amount FROM (SELECT * FROM products WHERE id=1) tmp2)-1
WHERE id=1 AND remaining_amount>0;
SELECT %%SLEEP_BEFORE_COMMIT%%;'

'-- SUBQUERY SET DELAY ON PRE-WRITE --
UPDATE products
SET
  referencing_amount_%%USER%%=(SELECT %%SLEEP_DELAY%%)+(SELECT remaining_amount FROM (SELECT * FROM products WHERE id=1) tmp1),
  remaining_amount=(SELECT remaining_amount FROM (SELECT * FROM products WHERE id=1) tmp2)-1
WHERE id=1 AND remaining_amount>0;
SELECT %%SLEEP_BEFORE_COMMIT%%;'

'-- SUBQUERY SET DELAY ON POST-WRITE --
UPDATE products
SET
  referencing_amount_%%USER%%=(SELECT remaining_amount FROM (SELECT * FROM products WHERE id=1) tmp1),
  remaining_amount=(SELECT remaining_amount FROM (SELECT * FROM products WHERE id=1) tmp2)-1+(SELECT %%SLEEP_DELAY%%)
WHERE id=1 AND remaining_amount>0;
SELECT %%SLEEP_BEFORE_COMMIT%%;'
)

for cmd in "${cmds[@]}"; do
    for sql in "${sqls[@]}"; do
        for isolation in "${isolations[@]}"; do
            if [[ "$cmd" == pg ]] && [[ "$isolation" == 'READ UNCOMMITTED' ]]; then
                continue
            fi
            for commit_delay in "${commit_delays[@]}"; do
              perform "$cmd" "$isolation" "$commit_delay" "$sql"
            done
        done
    done
done
