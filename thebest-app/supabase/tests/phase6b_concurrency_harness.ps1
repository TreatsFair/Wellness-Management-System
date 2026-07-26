<#
Runs genuine two-connection Phase 6B concurrency scenarios against an approved
disposable fixture.

The config file contains a database connection string. Keep it out of Git.

Usage:
  pwsh -File .\phase6b_concurrency_harness.ps1 `
    -Config .\phase6b_fixture.local.json

Each scenario must provide:
  name, action_a, action_b, verify_sql, cleanup_sql

The harness:
  * creates a small unlogged barrier table,
  * starts two independent psql sessions,
  * waits until both are ready,
  * releases both at the same UTC timestamp,
  * always runs cleanup in a finally block.
#>

[CmdletBinding()]
param(
  [Parameter(Mandatory = $true)]
  [string] $Config
)

$ErrorActionPreference = 'Stop'
$fixture = Get-Content -LiteralPath $Config -Raw | ConvertFrom-Json

if ([string]::IsNullOrWhiteSpace($fixture.connection_string) -or
    [string]::IsNullOrWhiteSpace($fixture.staff_user_id)) {
  throw 'Config requires connection_string and staff_user_id.'
}

$required = @(
  'double-confirm-appointment',
  'double-confirm-group',
  'final-therapist-future-booking',
  'final-room-future-booking',
  'confirm-versus-walkin',
  'post-commit-timeout-retry'
)

$present = @($fixture.scenarios | ForEach-Object { $_.name })
$missing = @($required | Where-Object { $_ -notin $present })

if ($missing.Count -gt 0) {
  throw "Missing required scenarios: $($missing -join ', ')"
}

function Invoke-Psql(
  [string] $Connection,
  [string] $Sql
) {
  $output = & psql `
    --no-psqlrc `
    --set ON_ERROR_STOP=1 `
    --dbname $Connection `
    --command $Sql 2>&1

  if ($LASTEXITCODE -ne 0) {
    throw ($output -join [Environment]::NewLine)
  }

  return $output
}

function New-SessionSql(
  [string] $Scenario,
  [string] $Participant,
  [string] $StaffId,
  [string] $GoAtUtc,
  [string] $ActionSql
) {
  $scenarioEscaped = $Scenario.Replace("'", "''")
  $participantEscaped = $Participant.Replace("'", "''")
  $staffEscaped = $StaffId.Replace("'", "''")
  $action = $ActionSql.Trim()

  return @"
insert into public.phase6b_test_barrier (
  scenario_name,
  participant_name,
  ready_at
)
values (
  '$scenarioEscaped',
  '$participantEscaped',
  clock_timestamp()
)
on conflict (scenario_name, participant_name)
do update set ready_at = excluded.ready_at;

do `$barrier`$
declare
  v_deadline timestamptz := clock_timestamp() + interval '20 seconds';
begin
  while (
    select count(*)
    from public.phase6b_test_barrier
    where scenario_name = '$scenarioEscaped'
  ) < 2 loop
    if clock_timestamp() >= v_deadline then
      raise exception 'Barrier timeout for $scenarioEscaped';
    end if;
    perform pg_sleep(0.05);
  end loop;

  while clock_timestamp() < '$GoAtUtc'::timestamptz loop
    perform pg_sleep(0.01);
  end loop;
end;
`$barrier`$;

begin;
select set_config('request.jwt.claim.sub', '$staffEscaped', true);
$action
commit;
"@
}

Invoke-Psql $fixture.connection_string @"
create unlogged table if not exists public.phase6b_test_barrier (
  scenario_name text not null,
  participant_name text not null,
  ready_at timestamptz not null default clock_timestamp(),
  primary key (scenario_name, participant_name)
);
"@ | Out-Null

foreach ($scenario in $fixture.scenarios) {
  $jobs = @()
  $scenarioName = [string] $scenario.name

  try {
    Write-Host "Running $scenarioName with two independent connections..."

    Invoke-Psql $fixture.connection_string @"
delete from public.phase6b_test_barrier
where scenario_name = '$($scenarioName.Replace("'", "''"))';
"@ | Out-Null

    $goAt = [DateTime]::UtcNow.AddSeconds(3).ToString(
      "yyyy-MM-ddTHH:mm:ss.fffZ"
    )

    $sqlA = New-SessionSql `
      $scenarioName `
      'A' `
      $fixture.staff_user_id `
      $goAt `
      $scenario.action_a

    $sqlB = New-SessionSql `
      $scenarioName `
      'B' `
      $fixture.staff_user_id `
      $goAt `
      $scenario.action_b

    $jobs += Start-Job -ScriptBlock {
      param($connection, $sql)
      $output = & psql `
        --no-psqlrc `
        --set ON_ERROR_STOP=1 `
        --dbname $connection `
        --command $sql 2>&1
      [pscustomobject]@{
        ExitCode = $LASTEXITCODE
        Output = @($output)
      }
    } -ArgumentList $fixture.connection_string, $sqlA

    $jobs += Start-Job -ScriptBlock {
      param($connection, $sql)
      $output = & psql `
        --no-psqlrc `
        --set ON_ERROR_STOP=1 `
        --dbname $connection `
        --command $sql 2>&1
      [pscustomobject]@{
        ExitCode = $LASTEXITCODE
        Output = @($output)
      }
    } -ArgumentList $fixture.connection_string, $sqlB

    Wait-Job -Job $jobs | Out-Null
    $results = @($jobs | ForEach-Object { Receive-Job -Job $_ })

    $failures = @(
      $results | Where-Object {
        $_.ExitCode -ne 0
      }
    )

    if ($failures.Count -gt 0) {
      $message = $failures |
        ForEach-Object { $_.Output -join [Environment]::NewLine }
      throw "Concurrent action failed:`n$($message -join "`n---`n")"
    }

    if (-not [string]::IsNullOrWhiteSpace($scenario.verify_sql)) {
      Invoke-Psql `
        $fixture.connection_string `
        ([string] $scenario.verify_sql) | Out-Host
    }

    Write-Host "$scenarioName passed."
  }
  finally {
    if ($jobs.Count -gt 0) {
      $jobs |
        Where-Object { $_.State -eq 'Running' } |
        Stop-Job -ErrorAction SilentlyContinue

      Remove-Job -Job $jobs -Force -ErrorAction SilentlyContinue
    }

    if (-not [string]::IsNullOrWhiteSpace($scenario.cleanup_sql)) {
      try {
        Invoke-Psql `
          $fixture.connection_string `
          ([string] $scenario.cleanup_sql) | Out-Null
      }
      catch {
        Write-Warning "Fixture cleanup failed for $scenarioName`: $_"
      }
    }

    try {
      Invoke-Psql $fixture.connection_string @"
delete from public.phase6b_test_barrier
where scenario_name = '$($scenarioName.Replace("'", "''"))';
"@ | Out-Null
    }
    catch {
      Write-Warning "Barrier cleanup failed for $scenarioName`: $_"
    }
  }
}

Invoke-Psql $fixture.connection_string @"
drop table if exists public.phase6b_test_barrier;
"@ | Out-Null

Write-Host 'All configured two-connection scenarios passed and were cleaned up.'
