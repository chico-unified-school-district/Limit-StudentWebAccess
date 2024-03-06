SELECT
 STU.ID AS permId
,STU.FN AS firstName
,STU.LN AS lastName
,STU.GR AS grade
,STU.SN AS stuNum
,STU.SC AS siteCode
FROM STU
WHERE id = {0} AND sc = {1};