# What's this?

Original Question: [sql - Is it really safe that running `UPDATE t SET v=v-1 WHERE id= ? and v>0` without pessimistic row locking? (MySQL/Postgres/Oracle) - Stack Overflow](https://stackoverflow.com/questions/72838226/is-it-really-safe-that-running-update-t-set-v-v-1-where-id-and-v0-without?noredirect=1#comment128657500_72838226)

> Assume that there is a table which controls stock amount information.
>
> ```sql
> CREATE TABLE products(
>     id INTEGER PRIMARY KEY,
>     remaining_amount INTEGER NOT NULL
> );
> INSERT INTO products(id, remaining_amount) VALUES (1, 1);
> ```
>
> Now, user A and B try to take the last stock at the same time.
>
> ```sql
> A/B: UPDATE products
>      SET remaining_amount = remaining_amount - 1
>      WHERE id = 1 and remaining_amount > 0;
> ```

I've found that for `UPDATE` statements which include the field to be updated in the `WHERE` condition, **a pessimistic lock is implicitly obtained regardless of transaction isolation levels**. So we don't have to execute explicitly `SELECT ... FOR UPDATE` before simple `UPDATE` statements. 

| A                                                                                         | B                                                                                         |
|:------------------------------------------------------------------------------------------|:------------------------------------------------------------------------------------------|
| `SET TRANSACTION ISOLATIONLEVEL READ UNCOMMITTED;`<br>`BEGIN;`                            | `SET TRANSACTION ISOLATIONLEVEL READ UNCOMMITTED;`<br>`BEGIN;`                            |
| `UPDATE products SET remaining_amount = remaining_amount - 1 WHERE remaining_amount > 0;` |                                                                                           |
| Query OK, 1 row affected<br>Rows **matched: 1  Changed: 1**  Warnings: 0                  |                                                                                           |
|                                                                                           | `UPDATE products SET remaining_amount = remaining_amount - 1 WHERE remaining_amount > 0;` |
|                                                                                           | **BLOCKED!!!**                                                                            |
| `COMMIT;`                                                                                 |                                                                                           |
|                                                                                           | Query OK, 0 rows affected<br>Rows **matched: 0  Changed: 0**  Warnings: 0                 |
|                                                                                           | `COMMIT;`                                                                                 |

However, it is not guaranteed to be conflict-free whenever a SELECT subquery is included. Our investigation revealed that the results vary depending on the transaction isolation level, as follows:

- `UPDATE t SET v=v-1 WHERE id=1 AND v>0`
- `UPDATE t SET v=v-1 WHERE EXISTS(SUBQUERY)`
- `UPDATE t SET v=(SUBQUERY)-1 WHERE id=1 AND v>0`

#### MySQL

|                  | Normal |      Subquery WHERE       | Subquery SET |
|:-----------------|:------:|:-------------------------:|:------------:|
| READ UNCOMMITTED |   ✅    |  ❌ Broken on Write Delay  |      ✅       |
| READ COMMITTED   |   ✅    |  ❌ Broken on Write Delay  |      ✅       |
| REPEATABLE READ  |   ✅    | ❗ Deadlock on Write Delay |      ✅       |
| SERIALIZABLE     |   ✅    |             ✅             |      ✅       |

#### Postgres

|                 |        Normal         |     Subquery WHERE     |     Subquery SET      |
|:----------------|:---------------------:|:----------------------:|:---------------------:|
| READ COMMITTED  |           ✅           |        ❌ Broken        |           ✅           |
| REPEATABLE READ | ❗ Serialization Error | ❗ Serialization Error  | ❗ Serialization Error |
| SERIALIZABLE    | ❗ Serialization Error | ❗ Serialization Error  | ❗ Serialization Error |