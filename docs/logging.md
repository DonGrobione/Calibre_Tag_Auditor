# Logging
All scripts log through the DonGrobione.Logging module. Each run writes one log file to `<Documents>\Logs\Calibre_Tag_Auditor\<HOSTNAME>_yyyy-MM-dd_HH-mm-ss.log`. When the pipeline runs, all steps share one log file; a step started on its own writes its own log file. The module keeps the 5 newest log files per computer and deletes older ones automatically. The scripts turn off the module's size-based rotation (`Start-Log -MaxFileSizeMB 0`), so a run is never split across several files, however long it takes. The project folder no longer contains log files.

Terminal output shows the same messages; warnings and errors are prefixed with `WARN:` or `ERROR:`.

To update the logging module:

```powershell
Update-DonGrobioneLogging
```
