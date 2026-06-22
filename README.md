# Data Science Job Market Analysis (Glassdoor, via Kaggle)

An end to end SQL project: cleaning a messy, real world Glassdoor jobs dataset and answering five business questions about pay, seniority, company revenue, and location using PostgreSQL window functions and aggregation.

## Why this project

Most cleaning tutorials use already tidy data. This dataset isn't tidy: it has `-1` sentinel values standing in for missing data, free text salary and revenue ranges that need parsing, open ended brackets like `"$10+ billion"` and `"10000+ employees"` with no defined upper bound, and a company name field with the Glassdoor rating glued onto it. The cleaning step is treated here as seriously as the analysis itself, because a wrong assumption at this stage silently breaks every query built on top of it.

## Dataset

[Data Science Jobs on Glassdoor (Kaggle)](https://www.kaggle.com/datasets/rashikrahmanpritom/data-science-job-posting-on-glassdoor), 672 job postings with salary estimate, company size, founding year, ownership type, industry, sector, revenue bracket, and rating.

| File | Description |
|---|---|
| `data/raw_glassdoor_jobs.csv` | Original, unprocessed dataset |
| `data/cleaned_jobs.csv` | Final cleaned output, used by all five analysis queries |
| `sql/01_data_cleaning.sql` | View definition that produces the cleaned dataset |
| `sql/02_analysis_queries.sql` | All five analysis queries, documented inline |
| `results/` | CSV export of each query's actual output |

## Cleaning approach

The raw data has a consistent pattern: missing or unusable values are encoded as the string `-1`, or occasionally `"Unknown"` / `"Unknown / Non-Applicable"`. Every cleaning step nulls these out explicitly rather than leaving them as misleading text or, worse, as a literal `-1` that could get summed or averaged into a numeric column by mistake.

Three transformations needed more care than a simple find and replace:

**Salary** is parsed from a free text estimate like `"$137K-$171K (Glassdoor est.)"` into two integer columns, `lowest_sal_thousands` and `highest_sal_thousands`, using regex to strip everything but digits and the separating hyphen.

**Company size** is split into `min_employees` and `max_employees`. The open ended `"10000+ employees"` bracket is given a `NULL` upper bound rather than an invented number, since there genuinely is no defined ceiling.

**Revenue** follows the same logic as company size, parsed into `min_revenue_millions` and `max_revenue_millions` from brackets like `"$500 million to $1 billion (USD)"`. The `"$10+ billion"` bracket is treated the same way as `"10000+ employees"`: `NULL` upper bound, not a sentinel integer. An earlier version of this view used `2^31 - 1` as a stand in "infinity" value here, which would have silently wrecked any `AVG()` or `SUM()` run over that column later. It was caught during review and replaced with `NULL`, for consistency with how company size already handled its own open ended bracket.

**Company name** required an extra step that isn't obvious from the column name alone: the raw field stores the name and Glassdoor rating concatenated with a newline, e.g. `"Healthfirst\n3.1"`. Left unsplit, this would have caused the same company to be treated as multiple distinct entities in any `GROUP BY company_name`, depending on what rating happened to be appended. `c_company_name` extracts everything before the newline.

## Methodology notes that apply across all five queries

A pattern shows up repeatedly in this dataset: many job titles, companies, and even states have very few postings behind them. A handful of postings producing an "average" that looks identical to a group with hundreds of postings is a real risk for misleading conclusions, not a hypothetical one. Every query below applies a minimum sample size filter (`HAVING COUNT(*) >= N`) before ranking or averaging, and reports the underlying count (`n`) alongside every result so the reader can judge how much to trust each number, rather than presenting a bare average as if all groups were equally reliable.

---

## Q1: Does a "Senior" title actually pay more?

```sql
SELECT job_title_short, AVG((lowest_sal_thousands+highest_sal_thousands)/2.0) AS avg_salary, COUNT(*) AS jobs_count
FROM jobs
WHERE job_title_short IN ('Senior Data Analyst', 'Data Analyst', 'Data Scientist', 'Senior Data Scientist')
GROUP BY job_title_short
ORDER BY avg_salary DESC;
```

| Role | Avg salary (K) | Postings |
|---|---|---|
| Senior Data Analyst | 127.0 | 10 |
| Data Scientist | 125.3 | 422 |
| Senior Data Scientist | 121.9 | 33 |
| Data Analyst | 115.1 | 37 |

The comparison that actually answers the question is within each role family, not the ranking across all four:

- **Analyst:** 115.1K to 127.0K, a **+11.9K** premium for Senior. Matches expectation.
- **Scientist:** 125.3K to 121.9K, a **-3.4K** dip for Senior. Does not match expectation.

The Scientist dip is unlikely to be a reliable signal. `Senior Data Scientist` has only 33 postings behind its average compared to 422 for the non senior title, and an average from a group that small is sensitive to a handful of underpaid outliers in a way that 422 postings is not. The honest conclusion is that seniority clearly pays off for Analysts in this dataset, while the Scientist result is directionally interesting but too thin to call a real pattern.

## Q2: Which company pays the most within each sector?

A top N per group window function: rank companies by average salary within each sector, restricted to companies with at least 4 postings.

```sql
WITH result_1 AS (
    SELECT clean_sector, c_company_name, AVG((lowest_sal_thousands+highest_sal_thousands)/2.0) AS avg_salary, COUNT(*) AS job_counts
    FROM jobs
    GROUP BY clean_sector, c_company_name
    HAVING COUNT(*) >= 4
),
ranks_added AS (
    SELECT *, RANK() OVER (PARTITION BY clean_sector ORDER BY avg_salary DESC) AS company_rank
    FROM result_1
)
SELECT clean_sector, c_company_name, company_rank, job_counts
FROM ranks_added
WHERE company_rank <= 3 AND clean_sector IS NOT NULL;
```

| Sector | #1 | #2 | #3 |
|---|---|---|---|
| Aerospace & Defense | Maxar Technologies (12) | | |
| Biotech & Pharmaceuticals | AstraZeneca (10) | Tempus Labs (11) | Novartis (5) |
| Business Services | Southwest Research Institute (6) | | |
| Government | Kingfisher Systems (4) | | |
| Information Technology | Triplebyte (4) | Klaviyo (8) | Novetta (6) |
| Insurance | MassMutual (5) | | |
| Manufacturing | Mars (4) | | |

The minimum posting threshold matters more than it might look like here. Without it, an early version of this query returned results where 72% of the "top 3" companies per sector had exactly one job posting behind their average, meaning a single salary figure was being presented as a representative company average. Raising the bar to 4+ postings dropped the result from 41 rows across 19 sectors down to 11 rows across 7, but every remaining row now reflects an actual pattern rather than a coincidence. The other 15 sectors in the dataset simply don't have enough postings per company to rank reliably, which is itself a fact about this dataset worth stating rather than hiding.

## Q3: Does company revenue correlate with salary?

Companies are bucketed by revenue midpoint into Small (under 100M), Mid (100M to 1B), and Large (1B to 10B). The open ended "$10+ billion" group has no upper bound to compute a midpoint from, so it's measured separately, labeled "Mega," using its floor value of 10000M.

```sql
WITH revenue_data AS (
    SELECT
        CASE
            WHEN (min_revenue_millions+max_revenue_millions)/2.0 < 100 THEN 'Small'
            WHEN (min_revenue_millions+max_revenue_millions)/2.0 < 1000 THEN 'Mid'
            ELSE 'Large'
        END AS revenue_bucket,
        AVG((lowest_sal_thousands+highest_sal_thousands)/2.0) AS avg_salary, COUNT(*) AS n
    FROM jobs WHERE max_revenue_millions IS NOT NULL GROUP BY revenue_bucket
),
big_companies AS (
    SELECT 'Mega' AS revenue_bucket, AVG((lowest_sal_thousands+highest_sal_thousands)/2.0) AS avg_salary, COUNT(*) AS n
    FROM jobs WHERE max_revenue_millions IS NULL GROUP BY revenue_bucket
)
SELECT * FROM revenue_data UNION ALL SELECT * FROM big_companies
ORDER BY CASE revenue_bucket WHEN 'Mega' THEN 1 WHEN 'Large' THEN 2 WHEN 'Mid' THEN 3 ELSE 4 END;
```

| Bucket | Avg salary (K) | Postings |
|---|---|---|
| Mega ($10B+) | 125.7 | 303 |
| Large ($1B-$10B) | 126.7 | 89 |
| Mid ($100M-$1B) | 124.0 | 113 |
| Small (under $100M) | 118.0 | 167 |

Small to Mid to Large climbs cleanly (118.0 to 124.0 to 126.7), a believable "bigger company pays more" trend backed by reasonable sample sizes in every bucket. The pattern breaks at the very top: Mega, with the largest sample of any bucket at 303 postings, pays slightly less on average than Large. This isn't sample noise given the size of the group; it appears to be a genuine finding that the very largest companies in this dataset don't pay the most on average, possibly because compensation at that scale relies more heavily on equity or bonus structures not captured in a base salary estimate. One caveat worth keeping in mind: Mega's figure isn't computed on a true midpoint like the other three buckets, since its upper bound is undefined, so it isn't perfectly apples to apples, though the direction of the finding is likely still real.

## Q4: Which states are strong on both job volume and pay?

Sorting by either volume or salary alone surfaces different states. To find locations that are genuinely strong on both, each state is ranked separately on each metric, and the two ranks are summed; a lower total reflects strength on both dimensions rather than just one.

```sql
WITH location_sal AS (
    SELECT location_short, AVG((lowest_sal_thousands+highest_sal_thousands)/2.0) AS avg_salary, COUNT(*) AS no_of_jobs
    FROM jobs GROUP BY location_short HAVING COUNT(*) >= 5
),
ranks_added AS (
    SELECT *, RANK() OVER (ORDER BY avg_salary DESC) AS sal_rank, RANK() OVER (ORDER BY no_of_jobs DESC) AS vol_rank
    FROM location_sal
)
SELECT location_short, avg_salary, no_of_jobs, sal_rank + vol_rank AS total_rank
FROM ranks_added
WHERE LENGTH(location_short) = 2
ORDER BY total_rank;
```

| State | Avg salary (K) | Postings | Combined rank |
|---|---|---|---|
| NY | 136.4 | 52 | 8 |
| VA | 126.8 | 89 | 9 |
| DC | 139.5 | 26 | 10 |
| TX | 136.1 | 17 | 13 |
| MA | 122.0 | 62 | 14 |
| CA | 120.6 | 165 | 15 |

New York, Virginia, and DC come out as the strongest combination of high posting volume and high pay. California is a notable case: it has by far the most postings of any state in the dataset (165, roughly three times NY's count), but a rank sum approach only credits ordinal position, not magnitude, so CA's enormous volume lead doesn't move its combined rank as much as the raw numbers might suggest. This is a known limitation of rank sum scoring worth being upfront about, rather than presenting the table as if it perfectly captures "how much better."

States with fewer than 5 postings were excluded before ranking; an earlier version of this query without that filter let a state with a single $271.5K posting rank near the top of the salary axis purely on one data point, which is the same small sample distortion seen in Q1 and Q2.

## Q5: How wide is the pay gap within the same job title?

Each title's postings are split into quartiles with `NTILE(4)`, then the gap between the top of the highest quartile and the bottom of the lowest quartile is computed, restricted to titles with at least 10 postings (fewer than that can't form four meaningful quartiles).

```sql
WITH title_sal AS (
    SELECT job_title_short, (lowest_sal_thousands+highest_sal_thousands)/2.0 AS mid_point_sal FROM jobs
),
result_1 AS (
    SELECT job_title_short, mid_point_sal, NTILE(4) OVER (PARTITION BY job_title_short ORDER BY mid_point_sal) AS rank_bucket
    FROM title_sal
    WHERE job_title_short IN (SELECT job_title_short FROM jobs GROUP BY job_title_short HAVING COUNT(*) >= 10)
),
bucket_stats AS (
    SELECT job_title_short, MIN(mid_point_sal) AS bucket_min, MAX(mid_point_sal) AS bucket_max, rank_bucket
    FROM result_1 GROUP BY job_title_short, rank_bucket
)
SELECT job_title_short,
    MAX(CASE WHEN rank_bucket = 4 THEN bucket_max END) AS top_quartile_max,
    MIN(CASE WHEN rank_bucket = 1 THEN bucket_min END) AS bottom_quartile_min,
    MAX(CASE WHEN rank_bucket = 4 THEN bucket_max END) - MIN(CASE WHEN rank_bucket = 1 THEN bucket_min END) AS pay_gap
FROM bucket_stats GROUP BY job_title_short ORDER BY pay_gap DESC;
```

| Title | Top quartile max (K) | Bottom quartile min (K) | Pay gap (K) |
|---|---|---|---|
| Data Scientist | 271.5 | 43.5 | 228.0 |
| Senior Data Scientist | 271.5 | 76.5 | 195.0 |
| Data Analyst | 185.0 | 43.5 | 141.5 |
| Machine Learning Engineer | 164.5 | 76.5 | 88.0 |
| Data Engineer | 164.5 | 76.5 | 88.0 |
| Senior Data Analyst | 164.5 | 76.5 | 88.0 |

Data Scientist has by far the widest internal pay range, nearly double the next closest title. This title alone covers everything from a $43.5K bottom quartile floor to a $271.5K top quartile ceiling, which suggests the role spans a much broader range of experience levels, company sizes, or geographies than the other titles do. The narrower titles (Machine Learning Engineer, Data Engineer, Senior Data Analyst) cluster at an identical $88K gap, partly because Glassdoor's salary estimates come in coarse, repeating bands, so smaller samples are more likely to land on the exact same boundary values.

## What this project demonstrates

- Designing a cleaning pipeline around real, inconsistent sentinel values rather than treating every column the same way
- Catching the difference between what a query is intended to do and what it actually outputs, including a case where the original SQL logic and its exported result disagreed
- Using `RANK()`, `NTILE()`, and conditional aggregation (`CASE` inside `MAX`/`MIN` as a pivot) appropriately, not just for syntax practice
- Applying a minimum sample size threshold before trusting any group average, and stating that threshold's effect on the result rather than omitting it
- Being explicit about where a method has a known limitation (the Mega revenue bucket, the rank sum approach in Q4) instead of presenting every number as equally certain
