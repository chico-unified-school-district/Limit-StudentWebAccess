--
-- Try to only update newer entries
UPDATE DSD SET DD = GETDATE()
WHERE
ID = {0}
AND DS = '{1}'
AND DD IS NULL
AND DTS > DATEADD(day,-5,getdate());
--