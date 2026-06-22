-- =====================================================================
-- Data Cleaning View: Glassdoor Data Science Job Postings
-- =====================================================================
-- Source table: staging_glassdoor_jobs (raw, unprocessed Kaggle dataset)
-- Output: cleaned_data view, later materialized as the `jobs` table
--         used in 02_analysis_queries.sql
--
-- This view handles, in a single pass:
--   1. Job title normalization (collapsing "Sr.", "Sr", "(Sr.)" variants)
--   2. Salary range parsing ("$137K-$171K" -> two integer columns)
--   3. Sentinel value cleanup (-1 and "Unknown" strings -> NULL)
--   4. Company size range parsing, including the open-ended "10000+" case
--   5. Location parsing (state/city extraction from "City, ST")
--   6. Revenue bracket parsing into numeric lower/upper bound columns,
--      including the open-ended "$10+ billion" case
--   7. Company name extraction (raw field has the Glassdoor rating
--      appended after a newline, e.g. "Healthfirst\n3.1")
-- =====================================================================

CREATE OR REPLACE VIEW cleaned_data AS
WITH result_1 AS (
	SELECT
		index_id,
	    TRIM(job_title) AS n_job_title,
	    CASE
	        -- Senior Data Scientist Checks
	        WHEN job_title ILIKE '%Senior Data Scientist%' 
	          OR job_title ILIKE '%Sr. Data Scientist%' 
	          OR job_title ILIKE '%Sr Data Scientist%' 
	          OR job_title ILIKE '%(Sr.) Data Scientist%' THEN 'Senior Data Scientist' -- Catches the parenthesis variation
	          
	        -- Senior Data Analyst Checks
	        WHEN job_title ILIKE '%Senior Data Analyst%' 
	          OR job_title ILIKE '%Sr. Data Analyst%' 
	          OR job_title ILIKE '%Sr Data Analyst%' 
	          OR job_title ILIKE '%(Sr.) Data Analyst%' THEN 'Senior Data Analyst'   -- Catches the parenthesis variation
	          
	        -- Standard Core Roles
	        WHEN job_title ILIKE '%Data Scientist%' THEN 'Data Scientist'
	        WHEN job_title ILIKE '%Data Analyst%' THEN 'Data Analyst'
	        
	        ELSE job_title
	    END AS job_title_short,
	
		SPLIT_PART(REGEXP_REPLACE(salary_estimate, '[^0-9-]', '', 'g'), '-', 1)::INT AS lowest_sal_thousands,
		SPLIT_PART(REGEXP_REPLACE(salary_estimate, '[^0-9-]', '', 'g'), '-', 2)::INT AS highest_sal_thousands,
	
		CASE
			WHEN rating::DECIMAL(2,1) < 1.0 OR rating::DECIMAL(2,1) > 5.0 THEN NULL
			ELSE rating
		END::DECIMAL(2,1) AS clean_rating,
		
		location,
		
		TRIM(CASE
	    		WHEN location LIKE '%,%' THEN SPLIT_PART(location, ',', REGEXP_COUNT(location, ',') + 1)
	    		ELSE location
			END) AS clean_location,
	
		NULLIF(TRIM(headquarters), '-1') AS clean_headquarters,
	
		CASE
			WHEN size = '-1' OR LOWER(size) = 'unknown' THEN NULL
			ELSE size
		END AS clean_size,
		job_description,
		founded,
		type_of_ownership,
		industry,
		sector,
		CASE 
			WHEN revenue = '-1' OR revenue = 'Unknown / Non-Applicable' THEN NULL
			ELSE revenue
		END AS clean_revenue,
		competitors,
		company_name,
		ROW_NUMBER() OVER(PARTITION BY index_id) AS row_num 
	FROM staging_glassdoor_jobs
)
SELECT
	index_id, 
	n_job_title,
	job_title_short,
	lowest_sal_thousands,
	highest_sal_thousands,
	clean_rating,
	location,
	clean_location AS location_short,
	clean_headquarters,
	job_description,
	TRIM(SPLIT_PART(company_name, E'\n', 1)) AS c_company_name,
	CASE
		WHEN clean_size LIKE '% to %' THEN SPLIT_PART(clean_size, ' to ', 1) 
		WHEN clean_size LIKE '%+%' THEN SPLIT_PART(clean_size, '+', 1)
		ELSE clean_size
	END::INT AS min_employees,
	CASE
		WHEN clean_size LIKE '% to %' THEN SPLIT_PART(SPLIT_PART(clean_size, ' to ', 2), ' ', 1)
		WHEN clean_size LIKE '%+%' THEN NULL
		ELSE clean_size
	END::INT AS max_employees,
	NULLIF(TRIM(founded), '-1')::INT AS clean_founded,
	NULLIF(NULLIF(TRIM(type_of_ownership), '-1'), 'Unknown') AS clean_ownership_type,
	NULLIF(TRIM(sector), '-1') AS clean_sector,
	NULLIF(TRIM(competitors), '-1') AS clean_competitors,
	NULLIF(TRIM(industry), '-1') AS clean_industry,

	clean_revenue,
	CASE
		WHEN clean_revenue ILIKE '%million%to%billion%' THEN REGEXP_REPLACE(SPLIT_PART(clean_revenue, ' to ', 1), '[^0-9]', '', 'g')::INT
		WHEN clean_revenue ILIKE '%to%million%' THEN REGEXP_REPLACE(SPLIT_PART(clean_revenue, ' to ', 1), '[^0-9]', '', 'g')::INT
		WHEN clean_revenue ILIKE '%to%billion%' THEN REGEXP_REPLACE(SPLIT_PART(clean_revenue, ' to ', 1), '[^0-9]', '', 'g')::INT * 1000
		WHEN clean_revenue ILIKE '%+ billion%' THEN REGEXP_REPLACE(SPLIT_PART(clean_revenue, '+', 1), '[^0-9]', '', 'g')::INT * 1000
		WHEN clean_revenue ILIKE '%less%million%' THEN 0
		ELSE NULL
	END::INT AS min_revenue_millions,

	CASE
		WHEN clean_revenue ILIKE '%million%to%billion%' THEN REGEXP_REPLACE(SPLIT_PART(clean_revenue, ' to ', 2), '[^0-9]', '', 'g')::INT * 1000
		WHEN clean_revenue ILIKE '%to%million%' THEN REGEXP_REPLACE(SPLIT_PART(clean_revenue, ' to ', 2), '[^0-9]', '', 'g')::INT
		WHEN clean_revenue ILIKE '%to%billion%' THEN REGEXP_REPLACE(SPLIT_PART(clean_revenue, ' to ', 2), '[^0-9]', '', 'g')::INT * 1000
		WHEN clean_revenue ILIKE '%+ billion%' THEN NULL
		WHEN clean_revenue ILIKE '%less%million%' THEN REGEXP_REPLACE(clean_revenue, '[^0-9]', '', 'g')::INT
		ELSE NULL
	END::INT AS max_revenue_millions
	
FROM result_1 WHERE row_num = 1;