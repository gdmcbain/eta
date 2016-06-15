package ghcvm.runtime.message;

import ghcvm.runtime.closure.StgClosure;

public abstract class Message extends StgClosure {
    protected boolean valid = true;
    public boolean isValid() { return valid; }
    public void invalidate() { valid = false; }
    public void execute(Capability cap) {
        barf("executeMessage: %p", this);
    }
}