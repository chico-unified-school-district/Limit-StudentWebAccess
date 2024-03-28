SELECT DISTINCT
  STU.ID AS permId
 ,STU.FN AS firstName
 ,STU.LN AS lastName
 ,STU.GR AS grade
 ,DSD.DY AS dayCount
 ,DSD.DS AS pbType
 ,LOG.USR AS staffUsr
 ,DSD.DD AS startDate
 ,NULL AS endDate
FROM
 DSD
 LEFT JOIN STU ON STU.ID = DSD.ID
 LEFT JOIN (
 SELECT DISTINCT ID,USR FROM LOG
 WHERE CD = 'DSDchg'
 AND CO = 'District Supplemental - Submission'
 ) AS LOG ON STU.ID = LOG.ID
WHERE
STU.TG = ' ' -- Active Students only!
AND ( DSD.DS = 'PB' OR DSD.DS = 'PBN') -- PBN is Penalty Box No End Date
AND (DSD.DEL IS NOT NULL OR DSD.DEL = 0)
-- endDate greater than 1 days ago
AND ( DSD.DD IS NULL OR DATEADD(day,DY,DSD.DD) > DATEADD(day,-1,GETDATE()) )
;