param(
  [Parameter(Mandatory = $true)]
  [string]$ConnectionString
)

$ErrorActionPreference = 'Stop'
$marker = 'M123_CONCURRENT_' + [Guid]::NewGuid().ToString('N')
$tempDirectory = Join-Path ([IO.Path]::GetTempPath()) $marker
[IO.Directory]::CreateDirectory($tempDirectory) | Out-Null

function Invoke-Psql {
  param([string]$Sql)
  $output = & psql $ConnectionString -X -v ON_ERROR_STOP=1 -A -t -c $Sql
  if ($LASTEXITCODE -ne 0) {
    throw "psql failed with exit code $LASTEXITCODE"
  }
  return ($output -join "`n").Trim()
}

try {
  $candidateSql = @'
select catalogue.id::text || '|' || slot.start_at::text
from public.online_booking_services catalogue
cross join lateral generate_series(
  current_date + 1,
  current_date + 30,
  interval '1 day'
) day
cross join lateral public.get_public_booking_slots_v2(
  catalogue.id,
  day::date,
  'none'
) slot
where catalogue.enabled
order by slot.start_at, catalogue.id
limit 1;
'@
  $candidate = Invoke-Psql $candidateSql
  if (-not $candidate.Contains('|')) {
    throw 'No future public-booking slot is available for the concurrency test.'
  }
  $parts = $candidate.Split('|', 2)
  $catalogueId = $parts[0]
  $startAt = $parts[1]

  $processes = @()
  foreach ($suffix in @('A', 'B')) {
    $sqlPath = Join-Path $tempDirectory "$suffix.sql"
    $stdoutPath = Join-Path $tempDirectory "$suffix.out"
    $stderrPath = Join-Path $tempDirectory "$suffix.err"
    $fingerprint = "$marker-$suffix"
    $phoneSuffix = if ($suffix -eq 'A') { '93' } else { '94' }
    $sql = @"
\set ON_ERROR_STOP on
select *
from public.create_public_booking_hold_v2(
  '$catalogueId'::uuid,
  '$startAt'::timestamptz,
  'none',
  'M123 Concurrent $suffix',
  '01234567$phoneSuffix',
  'm123-concurrent-$($suffix.ToLower())@example.test',
  '',
  'migration 123 concurrency test',
  '$fingerprint'
);
"@
    [IO.File]::WriteAllText($sqlPath, $sql)
    $processes += Start-Process `
      -FilePath 'psql' `
      -ArgumentList @($ConnectionString, '-X', '-f', $sqlPath) `
      -WindowStyle Hidden `
      -RedirectStandardOutput $stdoutPath `
      -RedirectStandardError $stderrPath `
      -PassThru
  }

  $processes | Wait-Process
  $successCount = @($processes | Where-Object { $_.ExitCode -eq 0 }).Count
  if ($successCount -lt 1) {
    $errors = Get-Content (Join-Path $tempDirectory '*.err') -ErrorAction SilentlyContinue
    throw "Both concurrent reservations failed.`n$errors"
  }

  $verifySql = @"
do `$verify`$
begin
  if not exists (
    select 1 from public.booking_holds
    where request_fingerprint in ('$marker-A', '$marker-B')
  ) then
    raise exception 'No concurrent hold was created';
  end if;
  if exists (
    select 1 from public.booking_holds
    where request_fingerprint in ('$marker-A', '$marker-B')
      and (
        assigned_therapist_id is null
        or assigned_room_id is null
        or expires_at > created_at + interval '10 minutes'
      )
  ) then
    raise exception 'A concurrent hold lacks exact ten-minute resources';
  end if;
  if exists (
    select 1
    from public.booking_holds a
    join public.booking_holds b
      on a.id < b.id
     and a.assigned_therapist_id = b.assigned_therapist_id
     and a.start_at < b.end_at
     and a.end_at > b.start_at
    where a.request_fingerprint in ('$marker-A', '$marker-B')
      and b.request_fingerprint in ('$marker-A', '$marker-B')
  ) then
    raise exception 'Concurrent holds double-booked an exact therapist';
  end if;
  if exists (
    select 1
    from public.booking_holds a
    join public.booking_holds b
      on a.id < b.id
     and a.assigned_room_unit_id is not null
     and a.assigned_room_unit_id = b.assigned_room_unit_id
     and a.start_at < b.end_at
     and a.end_at > b.start_at
    where a.request_fingerprint in ('$marker-A', '$marker-B')
      and b.request_fingerprint in ('$marker-A', '$marker-B')
  ) then
    raise exception 'Concurrent holds double-booked an exact room unit';
  end if;
end
`$verify`$;
"@
  Invoke-Psql $verifySql | Out-Null
  Write-Output "PASS: $successCount concurrent exact-resource hold(s) created without double booking."
}
finally {
  try {
    Invoke-Psql "delete from public.booking_holds where request_fingerprint in ('$marker-A', '$marker-B');" | Out-Null
  }
  catch {
    Write-Warning "Fixture cleanup failed: $($_.Exception.Message)"
  }
  if (Test-Path -LiteralPath $tempDirectory) {
    Remove-Item -LiteralPath $tempDirectory -Recurse -Force
  }
}
