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

## Detailed investigation on MySQL/Postgres

However, it is not guaranteed to be conflict-free whenever a `SELECT` subquery is included. Our investigation revealed that the results vary depending on the transaction isolation level, as follows:

- `UPDATE t SET v=v-1 WHERE id=1 AND v>0`
- `UPDATE t SET v=v-1 WHERE EXISTS(SUBQUERY)`
- `UPDATE t SET v=(SUBQUERY)-1 WHERE id=1 AND v>0`

## Postgres

- **For simple updates or subquery `SET`, use `READ COMMITTED`.**
- **For complex subquery `WHERE`, use `REPEATABLE READ` and retry on serialization errors.** 

|                 |        Simple         |    Subquery WHERE     |     Subquery SET      |
|:----------------|:---------------------:|:---------------------:|:---------------------:|
| READ COMMITTED  |           ✅           |     ❌ 5/6 Broken      |           ✅           |
| REPEATABLE READ | ❗ Serialization Error | ❗ Serialization Error | ❗ Serialization Error |
| SERIALIZABLE    | ❗ Serialization Error | ❗ Serialization Error | ❗ Serialization Error |

### Subquery WHERE with `READ COMMITTED` will be broken:

| [B] Latter ＼ [A] Former | Before-Read Delay | Pre-Write Delay | Post-Write Delay |
|:------------------------|:-----------------:|:---------------:|:----------------:|
| Act before A's commit   |     ❌ Broken      |    ❌ Broken     |     ❌ Broken     |
| Act after A's commit    |         ✅         |    ❌ Broken     |     ❌ Broken     |

## MySQL

- **For simple updates or subquery `SET`, any transaction isolation level works well.** `READ UNCOMMITTED` or `READ COMMITTED` are recommended.
- **For complex subquery `WHERE`, use `REPEATABLE READ` and retry on deadlock errors.**

|                  | Simple | Subquery WHERE | Subquery SET |
|:-----------------|:------:|:--------------:|:------------:|
| READ UNCOMMITTED |   ✅    |  ❌ 4/6 Broken  |      ✅       |  
| READ COMMITTED   |   ✅    |  ❌ 5/6 Broken  |      ✅       |
| REPEATABLE READ  |   ✅    | ❗ 1/6 Deadlock |      ✅       |
| SERIALIZABLE     |   ✅    | ❗ 1/6 Deadlock |      ✅       |

### Subquery WHERE with `READ UNCOMMITTED` will be broken:

| [B] Latter ＼ [A] Former | Before-Read Delay | Pre-Write Delay | Post-Write Delay |
|:------------------------|:-----------------:|:---------------:|:----------------:|
| Act before A's commit   |         ✅         |    ❌ Broken     |     ❌ Broken     |
| Act after A's commit    |         ✅         |    ❌ Broken     |     ❌ Broken     |

### Subquery WHERE with `READ COMMITTED` will be broken:

| [B] Latter ＼ [A] Former | Before-Read Delay | Pre-Write Delay | Post-Write Delay |
|:------------------------|:-----------------:|:---------------:|:----------------:|
| Act before A's commit   |     ❌ Broken      |    ❌ Broken     |     ❌ Broken     |
| Act after A's commit    |         ✅         |    ❌ Broken     |     ❌ Broken     |

### Subquery WHERE with `REPEATABLE READ` will get deadlocks:

| [B] Latter ＼ [A] Former | Before-Read Delay | Pre-Write Delay | Post-Write Delay |
|:------------------------|:-----------------:|:---------------:|:----------------:|
| Act before A's commit   |         ✅         |        ✅        |        ✅         |
| Act after A's commit    |         ✅         |        ✅        |    ❗ Deadlock    |

### Subquery WHERE with `SERIALIZABLE` will get deadlocks:

| [B] Latter ＼ [A] Former | Before-Read Delay | Pre-Write Delay | Post-Write Delay |
|:------------------------|:-----------------:|:---------------:|:----------------:|
| Act before A's commit   |         ✅         |        ✅        |    ❗ Deadlock    |
| Act after A's commit    |         ✅         |        ✅        |        ✅         |
