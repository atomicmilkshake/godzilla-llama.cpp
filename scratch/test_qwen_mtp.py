import sys
from pathlib import Path

# Add root folder to sys.path
sys.path.insert(0, str(Path(__file__).resolve().parents[1]))

from conversion.qwen import _Qwen35MtpMixin

# Mock classes to simulate filter_tensors behavior
class DummyBase:
    @classmethod
    def filter_tensors(cls, item):
        return item

class DummyTextModel(DummyBase):
    @classmethod
    def filter_tensors(cls, item):
        # Simply returns the item like base TextModel does for valid names
        return item

# Mock Qwen3.5/3.6 Model class inheriting from _Qwen35MtpMixin
class MockQwenModel(_Qwen35MtpMixin, DummyTextModel):
    model_arch = None
    no_mtp = False
    mtp_only = False
    _original_block_count = 28

# Let's override the TextModel reference in filter_tensors so it doesn't try to call the real TextModel
import conversion.qwen
conversion.qwen.TextModel = DummyTextModel

def test_mappings():
    # Set the original block count
    MockQwenModel._original_block_count = 28
    
    test_cases = [
        # Original Qwen 3.5 syntax
        ("model.mtp.layers.0.attention.q_proj.weight", "model.layers.28.attention.q_proj.weight"),
        ("model.mtp.fc.weight", "model.layers.28.eh_proj.weight"),
        ("model.mtp.pre_fc_norm_hidden.weight", "model.layers.28.hnorm.weight"),
        
        # Qwen 3.6 mtp_layer/mtp_layers syntax
        ("model.mtp_layer.layers.0.attention.q_proj.weight", "model.layers.28.attention.q_proj.weight"),
        ("model.mtp_layers.0.attention.q_proj.weight", "model.layers.28.attention.q_proj.weight"),
        ("model.mtp_layer.fc.weight", "model.layers.28.eh_proj.weight"),
        ("model.mtp_layer.pre_fc_norm_hidden.weight", "model.layers.28.hnorm.weight"),
        
        # Standard non-MTP weight to ensure it remains unchanged
        ("model.layers.0.attention.q_proj.weight", "model.layers.0.attention.q_proj.weight"),
    ]
    
    success = True
    for input_name, expected_output in test_cases:
        res = MockQwenModel.filter_tensors((input_name, lambda: None))
        output_name = res[0] if res else None
        if output_name == expected_output:
            print(f"PASS: {input_name} -> {output_name}")
        else:
            print(f"FAIL: {input_name} -> {output_name} (Expected: {expected_output})")
            success = False
            
    if success:
        print("\nAll MTP mapping test cases passed successfully!")
    else:
        print("\nSome test cases failed.")
        sys.exit(1)

if __name__ == "__main__":
    test_mappings()
