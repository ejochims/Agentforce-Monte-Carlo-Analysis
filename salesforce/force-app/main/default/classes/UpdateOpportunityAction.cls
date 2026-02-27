/**
 * UpdateOpportunityAction.cls
 *
 * PURPOSE:
 *   Invocable Apex class that updates an Opportunity's Stage, Close Date,
 *   or Amount based on instructions from the Agentforce Agent. Handles
 *   questions like:
 *     "Move Deal XYZ to Proposal/Price Quote"
 *     "Push the close date on Acme Corp to April 30th"
 *     "Update the amount on Deal ABC to $2.5M"
 *
 * SAFETY:
 *   Runs with sharing — users can only update opportunities they have
 *   edit access to. The action requires an explicit opportunity ID or name
 *   to prevent accidental bulk updates.
 *
 * @author  Salesforce Solution Engineering
 * @version 1.0
 * @apiVersion 62.0
 */
public with sharing class UpdateOpportunityAction {

    // Valid fields this action is allowed to update
    public static final Set<String> ALLOWED_FIELDS = new Set<String>{
        'STAGE', 'CLOSEDATE', 'AMOUNT'
    };

    public class ActionInput {

        @InvocableVariable(
            label='Opportunity ID'
            description='Salesforce ID of the opportunity to update (18-character). Preferred over name for accuracy.'
            required=false
        )
        public String opportunityId;

        @InvocableVariable(
            label='Opportunity Name (search)'
            description='Name or partial name of the opportunity to find and update. Used if Opportunity ID is not provided. If multiple matches are found, the action will ask for clarification.'
            required=false
        )
        public String opportunityName;

        @InvocableVariable(
            label='Field to Update'
            description='Which field to update. Must be one of: STAGE, CLOSEDATE, AMOUNT'
            required=true
        )
        public String fieldToUpdate;

        @InvocableVariable(
            label='New Value'
            description='The new value for the field. For STAGE: use the stage name exactly (e.g., "Proposal/Price Quote"). For CLOSEDATE: use YYYY-MM-DD format. For AMOUNT: use a number (e.g., 2500000).'
            required=true
        )
        public String newValue;
    }

    public class ActionOutput {

        @InvocableVariable(
            label='Success'
            description='True if the opportunity was updated successfully.'
        )
        public Boolean success;

        @InvocableVariable(
            label='Confirmation Message'
            description='Human-readable confirmation of what was updated, ready to deliver to the user.'
        )
        public String confirmationMessage;

        @InvocableVariable(
            label='Updated Opportunity Name'
            description='The name of the opportunity that was updated.'
        )
        public String updatedOpportunityName;

        @InvocableVariable(
            label='Updated Opportunity ID'
            description='The Salesforce ID of the updated opportunity.'
        )
        public String updatedOpportunityId;

        @InvocableVariable(
            label='Error Message'
            description='If success is false, contains a description of what went wrong.'
        )
        public String errorMessage;

        @InvocableVariable(
            label='Multiple Matches Found'
            description='True if the name search returned multiple opportunities. The agent should ask for clarification.'
        )
        public Boolean multipleMatchesFound;

        @InvocableVariable(
            label='Match Options JSON'
            description='If multiple matches were found, JSON array of options: [{id, name, stage, amount, closeDate}]'
        )
        public String matchOptionsJson;
    }

    @InvocableMethod(
        label='Update Opportunity'
        description='Updates an opportunity field (Stage, Close Date, or Amount) by opportunity name or ID. Use when the user wants to change a deal stage, push a close date, or update an amount. Always confirm with the user before calling this action.'
        category='Pipeline Management'
    )
    public static List<ActionOutput> updateOpportunity(List<ActionInput> inputs) {
        List<ActionOutput> outputs = new List<ActionOutput>();
        for (ActionInput input : inputs) {
            ActionOutput output = new ActionOutput();
            try {
                output = executeUpdate(input);
            } catch (DmlException e) {
                output.success = false;
                output.errorMessage = 'Update failed — you may not have edit access to this opportunity: ' + e.getDmlMessage(0);
            } catch (Exception e) {
                output.success = false;
                output.errorMessage = 'Unexpected error: ' + e.getMessage();
                System.debug(LoggingLevel.ERROR, 'UpdateOpportunityAction error: ' + e.getMessage());
            }
            outputs.add(output);
        }
        return outputs;
    }

    private static ActionOutput executeUpdate(ActionInput input) {
        ActionOutput output = new ActionOutput();

        // Validate field name
        String field = input.fieldToUpdate != null ? input.fieldToUpdate.toUpperCase().trim() : '';
        if (!ALLOWED_FIELDS.contains(field)) {
            output.success = false;
            output.errorMessage = 'Invalid field "' + input.fieldToUpdate + '". Allowed fields: STAGE, CLOSEDATE, AMOUNT.';
            return output;
        }

        if (String.isBlank(input.newValue)) {
            output.success = false;
            output.errorMessage = 'New value is required.';
            return output;
        }

        // Find the opportunity
        List<Opportunity> opps = findOpportunity(input);

        if (opps.isEmpty()) {
            output.success = false;
            output.errorMessage = 'No open opportunity found matching "'
                + (String.isNotBlank(input.opportunityName) ? input.opportunityName : input.opportunityId) + '".';
            return output;
        }

        if (opps.size() > 1 && String.isBlank(input.opportunityId)) {
            // Multiple matches — return options for the agent to clarify
            output.success = false;
            output.multipleMatchesFound = true;
            List<Map<String, Object>> options = new List<Map<String, Object>>();
            for (Opportunity opp : opps) {
                options.add(new Map<String, Object>{
                    'id'        => opp.Id,
                    'name'      => opp.Name,
                    'stage'     => opp.StageName,
                    'amount'    => opp.Amount,
                    'closeDate' => String.valueOf(opp.CloseDate)
                });
            }
            output.matchOptionsJson = JSON.serialize(options);
            output.errorMessage = 'Found ' + opps.size() + ' opportunities matching that name. Please specify which one.';
            return output;
        }

        Opportunity opp = opps[0];
        String previousValue = getPreviousValue(opp, field);

        // Apply the update
        applyFieldUpdate(opp, field, input.newValue);

        update opp;

        output.success = true;
        output.updatedOpportunityId = opp.Id;
        output.updatedOpportunityName = opp.Name;
        output.confirmationMessage = buildConfirmationMessage(opp.Name, field, previousValue, input.newValue);

        return output;
    }

    private static List<Opportunity> findOpportunity(ActionInput input) {
        if (String.isNotBlank(input.opportunityId)) {
            // Exact ID lookup
            String safeId = String.escapeSingleQuotes(input.opportunityId.trim());
            return [
                SELECT Id, Name, StageName, Amount, CloseDate
                FROM Opportunity
                WHERE Id = :safeId
                AND IsClosed = false
                LIMIT 1
            ];
        } else if (String.isNotBlank(input.opportunityName)) {
            // Name search — LIKE for partial matching
            String safeName = '%' + String.escapeSingleQuotes(input.opportunityName.trim()) + '%';
            return [
                SELECT Id, Name, StageName, Amount, CloseDate
                FROM Opportunity
                WHERE Name LIKE :safeName
                AND IsClosed = false
                ORDER BY Amount DESC NULLS LAST
                LIMIT 5
            ];
        }
        return new List<Opportunity>();
    }

    private static String getPreviousValue(Opportunity opp, String field) {
        if (field == 'STAGE') return opp.StageName;
        if (field == 'CLOSEDATE') return opp.CloseDate != null ? String.valueOf(opp.CloseDate) : 'not set';
        if (field == 'AMOUNT') return opp.Amount != null ? String.valueOf(opp.Amount) : 'not set';
        return '';
    }

    private static void applyFieldUpdate(Opportunity opp, String field, String newValue) {
        if (field == 'STAGE') {
            opp.StageName = newValue.trim();
        } else if (field == 'CLOSEDATE') {
            try {
                opp.CloseDate = Date.valueOf(newValue.trim());
            } catch (Exception e) {
                throw new IllegalArgumentException(
                    'Invalid date format "' + newValue + '". Use YYYY-MM-DD (e.g., 2026-03-31).'
                );
            }
        } else if (field == 'AMOUNT') {
            try {
                opp.Amount = Decimal.valueOf(newValue.trim().replaceAll('[^0-9.]', ''));
            } catch (Exception e) {
                throw new IllegalArgumentException(
                    'Invalid amount "' + newValue + '". Use a number (e.g., 2500000).'
                );
            }
        }
    }

    private static String buildConfirmationMessage(
        String oppName,
        String field,
        String previousValue,
        String newValue
    ) {
        String fieldLabel = field == 'STAGE' ? 'stage'
            : field == 'CLOSEDATE' ? 'close date'
            : 'amount';

        String formattedNew = field == 'AMOUNT'
            ? formatCurrency(Decimal.valueOf(newValue.trim().replaceAll('[^0-9.]', '')))
            : newValue;

        String formattedPrev = (field == 'AMOUNT' && previousValue != 'not set')
            ? formatCurrency(Decimal.valueOf(previousValue))
            : previousValue;

        return 'Done! Updated "' + oppName + '" — '
            + fieldLabel + ' changed from ' + formattedPrev
            + ' to ' + formattedNew + '.';
    }

    private static String formatCurrency(Decimal amount) {
        if (amount == null) return '$0';
        if (amount >= 1000000) return '$' + (amount / 1000000).setScale(1, RoundingMode.HALF_UP) + 'M';
        if (amount >= 1000) return '$' + (amount / 1000).setScale(0, RoundingMode.HALF_UP) + 'K';
        return '$' + amount.setScale(0, RoundingMode.HALF_UP);
    }
}
