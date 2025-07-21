select *
from {{ source('mock_data', 'ledger') }}
limit 10