SELECT
 STU.ID
,STU.GR
,STU.SN
,STU.SC
,DSP.DY
,DSP.DD
,DSP.ED
,DSP.IUN
from DSP LEFT JOIN STU ON stu.id = dsp.pid
where pid IS NOT NULL
AND DSP.DS = 'PB'
AND DY > 0
AND dsp.dts > DATEADD(year, -1, getdate());