# @version ^0.3.10
"""
A counter.
"""
count: public(uint256)

@external
def increase():
    self.count += 1  # one more
    assert self.count > 0, "overflow"
