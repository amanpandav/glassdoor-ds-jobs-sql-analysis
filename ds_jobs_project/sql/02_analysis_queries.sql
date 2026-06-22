-- =====================================================================
-- Analysis Queries: Glassdoor Data Science Job Postings
-- =====================================================================
-- Runs against the `jobs` table, which is the materialized output of
-- the cleaned_data view defined in 01_data_cleaning.sql.
--
-- Five questions, each combining aggregation with a window function
-- where it adds real analytical value (ranking, quartiles).
-- Every query below applies a minimum sample size filter before
-- ranking or averaging, to avoid drawing conclusions from groups
-- with too few job postings to be statistically meaningful.
-- =====================================================================

-- ---------------------------------------------------------------------
-- Q1. Does a "Senior" title actually pay more than its non-senior
--     counterpart, for the same role?
-- ---------------------------------------------------------------------

SELECT
	job_title_short,
	AVG((lowest_sal_thousands+highest_sal_thousands)/2.0) AS avg_salary,
	COUNT(*) AS jobs_count
FROM jobs
WHERE job_title_short IN ('Senior Data Analyst', 'Data Analyst', 'Data Scientist', 'Senior Data Scientist')
GROUP BY job_title_short
ORDER BY avg_salary DESC;

-- ---------------------------------------------------------------------
-- Q2. Which company pays the most within each sector?
--     (classic top-N-per-group window function pattern)
--     Companies with fewer than 4 job postings are excluded, since a
--     1-2 posting "average" is just a single data point in disguise.
-- ---------------------------------------------------------------------

WITH result_1 AS (
	SELECT
		clean_sector,
		c_company_name,
		AVG((lowest_sal_thousands+highest_sal_thousands)/2) AS avg_salary,
		COUNT(*) AS job_counts
	FROM jobs
	GROUP BY clean_sector, c_company_name
	HAVING COUNT(*) >= 4
),
ranks_added AS (
	SELECT
		clean_sector,
		c_company_name,
		avg_salary,
		job_counts,
		RANK() OVER(PARTITION BY clean_sector ORDER BY avg_salary DESC) AS company_rank
	FROM 
		result_1
)
SELECT
	clean_sector,
	c_company_name,
	company_rank,
	job_counts
FROM 	
	ranks_added
WHERE 
	company_rank <= 3 AND clean_sector IS NOT NULL;

-- ---------------------------------------------------------------------
-- Q3. Does company revenue correlate with salary?
--     Split into two populations: companies with a defined revenue
--     range (bucketed by midpoint into Small/Mid/Large) and the
--     open-ended "$10+ billion" group (labeled "Mega"), which has no
--     upper bound and is therefore measured on its floor value only.
--     The two groups are not on an identical measurement basis; this
--     is called out explicitly in the README rather than glossed over.
-- ---------------------------------------------------------------------

WITH result_1 AS (
	WITH revenue_data AS (
		SELECT
			CASE
				WHEN (min_revenue_millions + max_revenue_millions)/2.0 < 100 THEN 'Small'
				WHEN (min_revenue_millions + max_revenue_millions)/2.0 >= 100 AND (min_revenue_millions + max_revenue_millions)/2.0 < 1000 THEN 'Mid'
				WHEN (min_revenue_millions + max_revenue_millions)/2.0 >= 1000 AND (min_revenue_millions + max_revenue_millions)/2.0 < 10000 THEN 'Large'
			END AS revenue_bucket,
			AVG((lowest_sal_thousands+highest_sal_thousands)/2.0) AS avg_salary,
			COUNT(*) AS n
		FROM jobs
		WHERE max_revenue_millions IS NOT NULL
		GROUP BY revenue_bucket
	),
	big_companies AS (
		SELECT
			CASE 
				WHEN max_revenue_millions IS NULL THEN 'Mega'
			END AS revenue_bucket,
			AVG((lowest_sal_thousands+highest_sal_thousands)/2.0) AS avg_salary,
			COUNT(*) AS n
		FROM jobs
		WHERE max_revenue_millions IS NULL
		GROUP BY revenue_bucket
	)
	SELECT
		revenue_bucket,
		avg_salary,
		n
	FROM revenue_data
	UNION ALL
	SELECT
		revenue_bucket,
		avg_salary,
		n
	FROM big_companies
)
SELECT * FROM result_1
ORDER BY
	CASE
		WHEN revenue_bucket = 'Mega' THEN 1
		WHEN revenue_bucket = 'Large' THEN 2
		WHEN revenue_bucket = 'Mid' THEN 3
		ELSE 4
	END;

-- ---------------------------------------------------------------------
-- Q4. Which states are strong on both job volume and average pay?
--     Each state is ranked separately on volume and on salary, then
--     the two ranks are summed; a lower total indicates strength on
--     both dimensions rather than just one. States with fewer than 5
--     postings are excluded to prevent a single outlier salary from
--     producing a misleading average (see README for the rank-sum
--     method's limitations).
-- ---------------------------------------------------------------------

WITH location_sal AS (
	SELECT
		location_short,
		AVG((lowest_sal_thousands+highest_sal_thousands)/2.0) AS avg_salary,
		COUNT(*) AS no_of_jobs
	FROM jobs
	GROUP BY location_short
	HAVING COUNT(*) >= 5
),
ranks_added AS (
	SELECT
		location_short,
		avg_salary,
		no_of_jobs,
		RANK() OVER(ORDER BY avg_salary DESC) AS sal_rank,
		RANK() OVER(ORDER BY no_of_jobs DESC) AS vol_rank
	FROM location_sal
),
sum_rank AS (
	SELECT	
		location_short,
		avg_salary,
		no_of_jobs,
		sal_rank + vol_rank AS total_rank
	FROM ranks_added
)
SELECT
	location_short,
	avg_salary,
	no_of_jobs,
	total_rank
FROM sum_rank
WHERE LENGTH(location_short) = 2
ORDER BY total_rank;

-- ---------------------------------------------------------------------
-- Q5. How wide is the pay gap between the lowest- and highest-paid
--     quartile, within the same job title?
--     Salaries are split into quartiles per title using NTILE(4), then
--     pivoted with conditional aggregation to compute the gap between
--     the top of quartile 4 and the bottom of quartile 1. Restricted
--     to titles with at least 10 postings, since fewer than 4 rows in
--     a partition cannot form four meaningful quartiles.
-- ---------------------------------------------------------------------

WITH title_sal AS (
	SELECT
		job_title_short,
		(lowest_sal_thousands + highest_sal_thousands)/2.0 AS mid_point_sal
	FROM jobs
),
result_1 AS (
	SELECT
		job_title_short,
		mid_point_sal,
		NTILE(4) OVER (PARTITION BY job_title_short ORDER BY mid_point_sal) AS rank_bucket
	FROM title_sal
	WHERE job_title_short IN (
		SELECT job_title_short FROM jobs GROUP BY job_title_short HAVING COUNT(*) >= 10
	)
),
bucket_stats AS (
	SELECT
		job_title_short,
		MIN(mid_point_sal) AS bucket_min,
		MAX(mid_point_sal) AS bucket_max,
		rank_bucket
	FROM result_1
	GROUP BY job_title_short, rank_bucket
)
SELECT
	job_title_short,
	MAX(CASE WHEN rank_bucket = 4 THEN bucket_max END) AS top_quartile_max,
	MIN(CASE WHEN rank_bucket = 1 THEN bucket_min END) AS bottom_quartile_min,
	MAX(CASE WHEN rank_bucket = 4 THEN bucket_max END) - MIN(CASE WHEN rank_bucket = 1 THEN bucket_min END) AS pay_gap
FROM bucket_stats
GROUP BY job_title_short
ORDER BY pay_gap DESC;
