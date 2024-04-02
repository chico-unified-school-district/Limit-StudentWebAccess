SELECT TOP 1 USR FROM LOG
WHERE
ID = {0}
AND CD = 'DSDchg'
AND CO = 'District Supplemental - Submission'
AND DTS > DATEADD(minute,-5,getdate())
ORDER BY DTS ASC;