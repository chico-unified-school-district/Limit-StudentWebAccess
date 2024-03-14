SELECT DISTINCT
 STU.ID AS permId
,STU.FN AS firstName
,STU.LN AS lastName
,STU.GR AS grade
,DSP.DY AS dayCount
,DSP.DD AS startDate
,DSP.ED AS endDate
,DSP.IUN AS staffUsr
from DSP LEFT JOIN STU ON stu.id = dsp.pid
where pid IS NOT NULL
AND DSP.DS = 'PB'
AND DY > 0
AND (DSP.DEL = 0 OR DSP.DEL IS NULL)
AND DSP.ED > getdate()
AND dsp.dts > DATEADD(year, -1, getdate());