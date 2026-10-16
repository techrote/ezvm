"""Optional read-only EzVM companion. No VM/worker mutation path exists here."""
from ezvm_dashboard.app import main

if __name__ == '__main__':
    raise SystemExit(main())
