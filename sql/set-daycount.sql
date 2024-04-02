--
-- Try to only update newer entries
UPDATE DSD SET DY = '{0}'
WHERE
ID = {1}
AND DS = '{2}'
AND DTS > DATEADD(day,-5,getdate());
--
