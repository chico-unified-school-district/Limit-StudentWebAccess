--
-- Try to only update newer entries
UPDATE DSD SET DD = GETDATE()
WHERE
ID = @id
AND DS = @pbType
AND DD IS NULL
AND DTS > DATEADD(day,-5,getdate());
--