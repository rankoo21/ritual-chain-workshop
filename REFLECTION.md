# Reflection

> "What should be public, what should stay hidden, and what should be decided by
> AI versus by a human in a bounty system?"

The rules of the game should be fully public: the bounty title, the reward, the
rubric, the deadlines, and the fact that a given address submitted something.
This is what makes the contest fair and verifiable, and it lets participants
trust that everyone is judged by the same standard. The actual answers, however,
must stay hidden during the submission window, because visible answers let later
entrants copy and marginally improve on earlier work, which destroys originality
and punishes whoever submits first. The commit-reveal scheme enforces exactly
this: only a binding hash is public until the deadline, and answers become
visible (or are judged inside a TEE and never become public at all) only once no
new submissions can be made. As for the decision, AI is well suited to the
scalable, repetitive part — reading every submission against the rubric and
producing a consistent comparative review in a single batch pass. A human should
make the final, accountable call in `finalizeWinner`, because money is moving,
edge cases and intent matter, and someone must be answerable if the AI is wrong
or gamed by a cleverly worded prompt. In short: make the process transparent,
keep the content secret until it is safe to reveal, let AI scale the analysis,
and keep a human responsible for the payout.
